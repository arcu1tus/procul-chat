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

        // An IP literal needs no DNS, and Dns.GetHostAddresses throws for the unspecified
        // addresses (0.0.0.0 / ::) — handle literals directly so the result is a clean "blocked".
        if (System.Net.IPAddress.TryParse(uri.Host, out var literal))
        {
            return IsBlocked(literal)
                ? UrlPolicyResult.Blocked("Refusing to fetch a private or loopback address.")
                : UrlPolicyResult.Ok;
        }

        System.Net.IPAddress[] addresses;
        try
        {
            addresses = await System.Net.Dns.GetHostAddressesAsync(uri.Host, ct);
        }
        catch (Exception ex) when (ex is System.Net.Sockets.SocketException or ArgumentException)
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
        // An IPv4-mapped IPv6 address (::ffff:a.b.c.d) reaches the same host as its IPv4 form.
        // Normalize it first: otherwise it looks like an ordinary (public) IPv6 address and both
        // the loopback check and the v4 range checks are skipped — an SSRF bypass.
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        if (System.Net.IPAddress.IsLoopback(address))
        {
            return true;
        }

        var bytes = address.GetAddressBytes();

        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && bytes.Length == 4)
        {
            return bytes[0] switch
            {
                0 => true,                      // 0.0.0.0/8 "this network"
                10 => true,                     // 10.0.0.0/8
                100 when bytes[1] is >= 64 and <= 127 => true, // 100.64.0.0/10 CGNAT
                127 => true,                    // loopback
                169 when bytes[1] == 254 => true, // 169.254.0.0/16 link-local (incl. cloud metadata)
                172 when bytes[1] is >= 16 and <= 31 => true, // 172.16.0.0/12
                192 when bytes[1] == 0 && bytes[2] == 0 => true, // 192.0.0.0/24
                192 when bytes[1] == 168 => true, // 192.168.0.0/16
                198 when bytes[1] is >= 18 and <= 19 => true, // 198.18.0.0/15 benchmarking
                >= 224 => true,                 // 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
                _ => false,
            };
        }

        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 && bytes.Length == 16)
        {
            // Unspecified (::), unique-local (fc00::/7), link-local (fe80::/10), multicast (ff00::/8);
            // loopback handled above, and IPv4-mapped addresses are normalized before this point.
            return address.Equals(System.Net.IPAddress.IPv6Any)
                || (bytes[0] & 0xFE) == 0xFC
                || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)
                || bytes[0] == 0xFF;
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
