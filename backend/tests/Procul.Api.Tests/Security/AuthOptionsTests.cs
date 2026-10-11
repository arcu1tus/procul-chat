using Procul.Api.Configuration;
using Procul.Api.Security;

namespace Procul.Api.Tests.Security;

public class AuthOptionsTests
{
    [Fact]
    public void A_missing_password_fails_fast() =>
        Assert.Throws<InvalidOperationException>(() => Options());

    [Fact]
    public void An_empty_password_fails_fast() =>
        Assert.Throws<InvalidOperationException>(() => Options(password: ""));

    [Fact]
    public void The_session_lifetime_defaults_to_thirty_days()
    {
        var options = Options(password: "secret");

        Assert.Equal(TimeSpan.FromDays(30), options.SessionLifetime);
        Assert.Equal("secret", options.Password);
    }

    [Theory]
    [InlineData("30d", 30 * 24 * 60 * 60)]
    [InlineData("12h", 12 * 60 * 60)]
    [InlineData("90m", 90 * 60)]
    [InlineData("45s", 45)]
    [InlineData("1h30m", 90 * 60)]
    [InlineData("1d12h", 36 * 60 * 60)]
    [InlineData(" 2h ", 2 * 60 * 60)]
    public void Valid_lifetimes_are_parsed(string raw, int expectedSeconds)
    {
        var options = Options(password: "secret", lifetime: raw);

        Assert.Equal(TimeSpan.FromSeconds(expectedSeconds), options.SessionLifetime);
    }

    [Theory]
    [InlineData("30")]
    [InlineData("d")]
    [InlineData("30x")]
    [InlineData("h30")]
    [InlineData("1.5h")]
    [InlineData("-1d")]
    [InlineData("0d")]
    [InlineData("30d5")]
    public void Malformed_lifetimes_fail_fast(string raw) =>
        Assert.Throws<InvalidOperationException>(() => Options(password: "secret", lifetime: raw));

    private static AuthOptions Options(string? password = null, string? lifetime = null) =>
        AuthOptions.FromConfig(
            new ProculConfig { Server = new ServerConfig { SessionLifetime = lifetime } },
            password);
}
