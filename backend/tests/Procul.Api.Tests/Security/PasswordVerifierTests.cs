using Procul.Api.Security;

namespace Procul.Api.Tests.Security;

public class PasswordVerifierTests
{
    private static readonly PasswordVerifier Verifier = new("correct horse battery staple");

    [Fact]
    public void The_configured_password_verifies() =>
        Assert.True(Verifier.Verify("correct horse battery staple"));

    [Theory]
    [InlineData("wrong password")]
    [InlineData("correct horse battery stapl")] // one char short
    [InlineData("correct horse battery staple ")] // trailing space
    [InlineData("Correct Horse Battery Staple")] // different case
    [InlineData("")]
    [InlineData(null)]
    public void A_different_password_does_not_verify(string? supplied) =>
        Assert.False(Verifier.Verify(supplied));
}
