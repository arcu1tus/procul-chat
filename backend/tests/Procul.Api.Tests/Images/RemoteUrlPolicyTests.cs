using Procul.Api.Images;

namespace Procul.Api.Tests.Images;

/// <summary>
/// Locks in the SSRF guardrails: non-http(s) schemes, loopback, private/link-local/CGNAT ranges,
/// and — critically — IPv4-mapped IPv6 forms (<c>::ffff:a.b.c.d</c>), which reach the same host as
/// their IPv4 form and must not slip past the range checks. Every case uses a literal address, so
/// the policy's DNS step never touches the network.
/// </summary>
public class RemoteUrlPolicyTests
{
    private readonly SsrfRemoteUrlPolicy _policy = new();

    [Theory]
    [InlineData("file:///etc/passwd")]              // non-http(s) scheme
    [InlineData("ftp://example.com/x")]
    [InlineData("http://localhost/x")]              // hostname shortcut
    [InlineData("http://127.0.0.1/x")]              // loopback
    [InlineData("http://127.1.2.3/x")]
    [InlineData("http://[::1]/x")]                  // IPv6 loopback
    [InlineData("http://10.0.0.1/x")]               // private
    [InlineData("http://172.16.0.1/x")]
    [InlineData("http://192.168.1.1/x")]
    [InlineData("http://169.254.169.254/x")]        // link-local / cloud metadata
    [InlineData("http://100.64.0.1/x")]             // CGNAT
    [InlineData("http://198.18.0.1/x")]             // benchmarking
    [InlineData("http://0.0.0.0/x")]                // "this network"
    [InlineData("http://[fe80::1]/x")]              // IPv6 link-local
    [InlineData("http://[fc00::1]/x")]              // IPv6 unique-local
    [InlineData("http://[::]/x")]                   // IPv6 unspecified
    [InlineData("http://[::ffff:127.0.0.1]/x")]     // IPv4-mapped loopback (the bypass)
    [InlineData("http://[::ffff:169.254.169.254]/x")]
    [InlineData("http://[::ffff:10.0.0.1]/x")]
    public async Task Blocks_internal_and_non_http_urls(string url)
    {
        var result = await _policy.CanFetchAsync(new Uri(url), CancellationToken.None);

        Assert.False(result.Allowed, $"Expected '{url}' to be blocked.");
        Assert.NotNull(result.Error);
    }

    [Theory]
    [InlineData("https://93.184.216.34/x")] // a public literal, no DNS needed
    [InlineData("http://[2606:4700:4700::1111]/x")] // public IPv6 (Cloudflare DNS)
    public async Task Allows_public_addresses(string url)
    {
        var result = await _policy.CanFetchAsync(new Uri(url), CancellationToken.None);

        Assert.True(result.Allowed, $"Expected '{url}' to be allowed: {result.Error}");
    }
}
