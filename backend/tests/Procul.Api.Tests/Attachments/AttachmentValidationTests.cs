using Procul.Api.Attachments;

namespace Procul.Api.Tests.Attachments;

/// <summary>Wildcard content-type matching and file-name sanitization.</summary>
public class AttachmentValidationTests
{
    private static readonly string[] Allowed =
        ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"];

    [Theory]
    [InlineData("image/png", true)]
    [InlineData("image/jpeg", true)]
    [InlineData("IMAGE/PNG", true)]
    [InlineData("text/plain", true)]
    [InlineData("text/markdown", true)]
    [InlineData("application/pdf", true)]
    [InlineData("audio/mpeg", true)]
    [InlineData("audio/wav", true)]
    [InlineData("video/mp4", false)]
    [InlineData("application/zip", false)]
    [InlineData("image", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Matches_exact_and_wildcard_patterns(string? contentType, bool expected) =>
        Assert.Equal(expected, AttachmentValidation.IsAllowedContentType(contentType, Allowed));

    [Fact]
    public void A_bare_star_does_not_match() =>
        Assert.False(AttachmentValidation.IsAllowedContentType("image/png", ["*"]));

    [Theory]
    [InlineData("photo.png", "photo.png")]
    [InlineData("/etc/passwd", "passwd")]
    [InlineData("../secrets.txt", "secrets.txt")]
    [InlineData(@"C:\Users\me\file.txt", "file.txt")]
    [InlineData("   ", "file")]
    [InlineData("", "file")]
    public void SanitizeFileName_strips_any_directory_component(string input, string expected) =>
        Assert.Equal(expected, AttachmentValidation.SanitizeFileName(input));

    [Fact]
    public void SanitizeFileName_caps_the_length()
    {
        var name = new string('a', 900);
        Assert.Equal(512, AttachmentValidation.SanitizeFileName(name).Length);
    }
}
