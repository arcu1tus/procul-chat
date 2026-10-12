namespace Procul.Api.Images;

/// <summary>The outcome of a URL-safety check.</summary>
public sealed record UrlPolicyResult(bool Allowed, string? Error)
{
    public static readonly UrlPolicyResult Ok = new(true, null);

    public static UrlPolicyResult Blocked(string reason) => new(false, reason);
}

/// <summary>
/// Decides whether the backend may fetch a user/model-supplied URL. The default implementation
/// blocks non-http(s) schemes and private/loopback/link-local addresses (SSRF guardrails); tests
/// can substitute a permissive policy.
/// </summary>
public interface IRemoteUrlPolicy
{
    /// <summary>Whether <paramref name="uri"/> may be fetched, with a reason when it may not.</summary>
    Task<UrlPolicyResult> CanFetchAsync(Uri uri, CancellationToken ct);
}

/// <summary>
/// Blocks anything that is not a public <c>http</c>/<c>https</c> URL: other schemes, loopback,
/// private (RFC 1918), link-local, and unique-local addresses. Hostnames are resolved first so a
/// name that points at an internal address is rejected too.
/// </summary>
public sealed class SsrfRemoteUrlPolicy : IRemoteUrlPolicy
{
    public async Task<UrlPolicyResult> CanFetchAsync(Uri uri, CancellationToken ct)
    {
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
        {
            return UrlPolicyResult.Blocked($"Only http(s) URLs are allowed, not '{uri.Scheme}'.");
        }

        if (uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
        {
            return UrlPolicyResult.Blocked("Refusing to fetch a loopback address.");
        }

        System.Net.IPAddress[] addresses;
        try
        {
            addresses = await System.Net.Dns.GetHostAddressesAsync(uri.Host, ct);
        }
        catch (System.Net.Sockets.SocketException)
        {
            return UrlPolicyResult.Blocked($"Could not resolve the host '{uri.Host}'.");
        }

        if (addresses.Length == 0)
        {
            return UrlPolicyResult.Blocked($"Could not resolve the host '{uri.Host}'.");
        }

        foreach (var address in addresses)
        {
            if (IsBlocked(address))
            {
                return UrlPolicyResult.Blocked("Refusing to fetch a private or loopback address.");
            }
        }

        return UrlPolicyResult.Ok;
    }

    private static bool IsBlocked(System.Net.IPAddress address)
    {
        if (System.Net.IPAddress.IsLoopback(address))
        {
            return true;
        }

        var bytes = address.GetAddressBytes();

        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && bytes.Length == 4)
        {
            return bytes[0] switch
            {
                10 => true,                     // 10.0.0.0/8
                127 => true,                    // loopback
                169 when bytes[1] == 254 => true, // link-local
                172 when bytes[1] is >= 16 and <= 31 => true, // 172.16.0.0/12
                192 when bytes[1] == 168 => true, // 192.168.0.0/16
                0 => true,                      // "this network"
                _ => false,
            };
        }

        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 && bytes.Length == 16)
        {
            // Unique-local (fc00::/7) and link-local (fe80::/10); loopback handled above.
            return (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80);
        }

        return false;
    }
}

/// <summary>A policy that allows every http(s) URL. For unit tests only.</summary>
internal sealed class PermissiveRemoteUrlPolicy : IRemoteUrlPolicy
{
    public Task<UrlPolicyResult> CanFetchAsync(Uri uri, CancellationToken ct) =>
        Task.FromResult(
            uri.Scheme is "http" or "https"
                ? UrlPolicyResult.Ok
                : UrlPolicyResult.Blocked("Only http(s) URLs are allowed."));
}
