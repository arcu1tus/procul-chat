using System.ComponentModel;
using Microsoft.Extensions.AI;
using Procul.Api.Attachments;
using Procul.Api.Images;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// The <c>show_image</c> tool: downloads an image from a public URL (or decodes base64 bytes),
/// stores it through <see cref="IAttachmentStore"/>, and surfaces it to the client via the
/// <c>image</c> SSE event. The URL path is gated by <see cref="IRemoteUrlPolicy"/> (SSRF guardrails)
/// and every path is bounded by the configured upload size cap.
/// </summary>
internal sealed class ShowImageTool(
    IHttpClientFactory httpClientFactory,
    IRemoteUrlPolicy urlPolicy,
    TurnToolContext context,
    ILogger logger)
{
    internal const string ClientName = "show-image";

    /// <summary>The wall-clock budget for a single URL fetch.</summary>
    private static readonly TimeSpan FetchTimeout = TimeSpan.FromSeconds(30);

    public AIFunction Create() => AIFunctionFactory.Create(ShowImageAsync, "show_image");

    [Description("Display an image in the chat from a public URL or base64-encoded image bytes. " +
                 "The image is downloaded/decoded and shown to the user.")]
    private async Task<string> ShowImageAsync(
        [Description("A public http(s) URL of the image.")] string? url = null,
        [Description("Base64-encoded image bytes (with or without a data: prefix).")] string? base64 = null,
        [Description("Optional file name to show.")] string? fileName = null,
        CancellationToken ct = default)
    {
        var hasUrl = !string.IsNullOrWhiteSpace(url);
        var hasBase64 = !string.IsNullOrWhiteSpace(base64);
        if (hasUrl == hasBase64)
        {
            return "Provide exactly one of 'url' or 'base64'.";
        }

        try
        {
            var (bytes, contentType) = hasUrl
                ? await FetchUrlAsync(url!, ct)
                : DecodeBase64(base64!, context.AttachmentOptions.MaxFileSizeBytes);

            if (bytes.Length > context.AttachmentOptions.MaxFileSizeBytes)
            {
                return $"The image is too large ({bytes.Length} bytes; the limit is " +
                       $"{context.AttachmentOptions.MaxFileSizeBytes} bytes).";
            }

            var name = string.IsNullOrWhiteSpace(fileName)
                ? $"shown-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}.{ExtensionFor(contentType)}"
                : AttachmentValidation.SanitizeFileName(fileName);

            await ToolMedia.StoreAsync(context, bytes, name, contentType, ct);
            return $"Displayed the image ({contentType}, {bytes.Length} bytes) in the chat.";
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "show_image failed");
            return $"Could not display the image: {ex.Message}";
        }
    }

    private async Task<(byte[] Bytes, string ContentType)> FetchUrlAsync(string rawUrl, CancellationToken ct)
    {
        if (!Uri.TryCreate(rawUrl.Trim(), UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException($"'{rawUrl}' is not an absolute URL.");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(FetchTimeout);

        using var http = httpClientFactory.CreateClient(ClientName);
        http.Timeout = Timeout.InfiniteTimeSpan; // the linked CTS bounds the call instead

        using var response = await FetchWithRedirectsAsync(http, uri, timeout.Token);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"The URL returned {(int)response.StatusCode}.");
        }

        var declared = response.Content.Headers.ContentType?.MediaType;
        var declaredLength = response.Content.Headers.ContentLength;
        if (declaredLength is > 0 && declaredLength > context.AttachmentOptions.MaxFileSizeBytes)
        {
            throw new InvalidOperationException("The remote image exceeds the configured size limit.");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        var bytes = await ReadCappedAsync(stream, context.AttachmentOptions.MaxFileSizeBytes, timeout.Token);

        var contentType = ImageTypeDetector.DetectOrNull(bytes);
        if (contentType is null)
        {
            if (!string.IsNullOrWhiteSpace(declared)
                && declared.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
            {
                contentType = declared.Trim();
            }
            else
            {
                throw new InvalidOperationException(
                    $"The URL did not return an image (content type '{declared ?? "unknown"}').");
            }
        }

        return (bytes, contentType);
    }

    private async Task<HttpResponseMessage> FetchWithRedirectsAsync(HttpClient http, Uri uri, CancellationToken ct)
    {
        for (var redirects = 0; ; redirects++)
        {
            var policy = await urlPolicy.CanFetchAsync(uri, ct);
            if (!policy.Allowed)
            {
                throw new InvalidOperationException(policy.Error ?? "The URL is not allowed.");
            }

            var response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode is not (System.Net.HttpStatusCode.MovedPermanently
                or System.Net.HttpStatusCode.Found or System.Net.HttpStatusCode.SeeOther
                or System.Net.HttpStatusCode.TemporaryRedirect or System.Net.HttpStatusCode.PermanentRedirect))
            {
                return response;
            }

            using (response)
            {
                if (redirects >= 5)
                {
                    throw new InvalidOperationException("The image URL redirected too many times.");
                }

                if (response.Headers.Location is not { } location)
                {
                    throw new InvalidOperationException("The image URL returned a redirect without a destination.");
                }

                uri = new Uri(uri, location);
            }
        }
    }

    private static (byte[] Bytes, string ContentType) DecodeBase64(string raw, long maxBytes)
    {
        var value = raw.Trim();

        string? declared = null;

        if (value.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
        {
            var comma = value.IndexOf(',');
            if (comma < 0)
            {
                throw new InvalidOperationException("The data URL is malformed.");
            }

            var header = value[5..comma]; // e.g. "image/png;base64"
            var semicolon = header.IndexOf(';');
            declared = semicolon >= 0 ? header[..semicolon] : header;
            value = value[(comma + 1)..];
        }

        // Count the encoded bytes, excluding the data URL header and whitespace, before
        // allocating a normalized payload. Padding rounds base64 up to a multiple of four.
        if (value.Count(character => !char.IsWhiteSpace(character)) > (maxBytes / 3 + (maxBytes % 3 == 0 ? 0 : 1)) * 4)
        {
            throw new InvalidOperationException("The base64 payload exceeds the configured size limit.");
        }

        // Tolerate whitespace/newlines in a pasted base64 payload.
        value = new string(value.Where(character => !char.IsWhiteSpace(character)).ToArray());

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(value);
        }
        catch (FormatException)
        {
            throw new InvalidOperationException("The base64 payload is not valid base64.");
        }

        if (bytes.Length == 0)
        {
            throw new InvalidOperationException("The base64 payload decoded to zero bytes.");
        }

        var contentType = ImageTypeDetector.Detect(bytes, declared);
        if (!contentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"The payload is not an image (content type '{contentType}').");
        }

        return (bytes, contentType);
    }

    /// <summary>Reads at most <paramref name="maxBytes"/> + 1 bytes so an oversized stream is caught.</summary>
    private static async Task<byte[]> ReadCappedAsync(Stream stream, long maxBytes, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[81_920];
        int read;

        while ((read = await stream.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > maxBytes)
            {
                throw new InvalidOperationException("The remote image exceeds the configured size limit.");
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    private static string ExtensionFor(string contentType) => contentType.Trim().ToLowerInvariant() switch
    {
        "image/png" => "png",
        "image/jpeg" or "image/jpg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/bmp" => "bmp",
        _ => "png",
    };
}
