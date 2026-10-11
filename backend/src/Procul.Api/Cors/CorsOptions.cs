using Procul.Api.Configuration;

namespace Procul.Api.Cors;

/// <summary>
/// Browser-origin settings derived from <c>server.corsAllowedOrigins</c> in <c>config.jsonc</c>.
/// An empty list means "not configured" and is resolved per environment by the caller.
/// </summary>
public sealed class CorsOptions
{
    /// <summary>Validated, normalized origins (no trailing slash). Empty when unconfigured.</summary>
    public required IReadOnlyList<string> AllowedOrigins { get; init; }

    /// <summary>Builds and validates the options from the config.</summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when an origin is a wildcard or is not an absolute http(s) origin, so a
    /// misconfiguration fails fast at startup instead of silently blocking every browser client.
    /// </exception>
    public static CorsOptions FromConfig(ProculConfig config) =>
        new() { AllowedOrigins = ParseOrigins(config.Server.CorsAllowedOrigins) };

    /// <summary>
    /// Trims, validates and normalizes the configured origins. A wildcard or a value that is not an
    /// absolute http(s) origin without a path is fatal.
    /// </summary>
    internal static IReadOnlyList<string> ParseOrigins(IEnumerable<string> origins)
    {
        var normalized = new List<string>();

        foreach (var raw in origins)
        {
            var value = raw.Trim();
            if (value.Length == 0)
            {
                continue;
            }

            if (value == "*")
            {
                throw new InvalidOperationException(
                    "server.corsAllowedOrigins must list explicit origins; a wildcard ('*') is not " +
                    "allowed. Set it to the frontend's origin(s), e.g. https://app.example.com.");
            }

            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
                || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
                || uri.AbsolutePath != "/")
            {
                throw new InvalidOperationException(
                    $"server.corsAllowedOrigins contains '{value}', which is not a valid origin. " +
                    "Expected an absolute http(s) origin without a path, e.g. https://app.example.com.");
            }

            // CORS origin matching is an exact string comparison, so normalize away a trailing
            // slash and any default port the browser would omit.
            normalized.Add(uri.GetLeftPart(UriPartial.Authority));
        }

        return normalized;
    }
}
