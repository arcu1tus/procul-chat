using System.Text;
using Microsoft.Extensions.AI;
using Procul.Api.Attachments;
using Procul.Api.Chat;

namespace Procul.Api.Tests.Attachments;

/// <summary>Every row of the attachment → <see cref="AIContent"/> mapping table.</summary>
public class AttachmentContentBuilderTests
{
    private const long InlineCap = 16;

    private static Attachment Attachment(string fileName, string contentType, long size = 0) =>
        new() { FileName = fileName, ContentType = contentType, SizeBytes = size };

    private static HashSet<ModelInputModality> Caps(params ModelInputModality[] modalities) => [.. modalities];

    private static readonly HashSet<ModelInputModality> AllCaps =
        Caps(ModelInputModality.Text, ModelInputModality.Image, ModelInputModality.Audio, ModelInputModality.Pdf);

    [Fact]
    public void An_image_becomes_a_data_content_with_the_image_media_type()
    {
        var bytes = new byte[] { 1, 2, 3 };

        var parts = AttachmentContentBuilder.Build(
            Attachment("cat.png", "image/png"), bytes, AllCaps, InlineCap);

        var data = Assert.IsType<DataContent>(Assert.Single(parts));
        Assert.Equal("image/png", data.MediaType);
        Assert.Equal(bytes, data.Data.ToArray());
    }

    [Fact]
    public void A_pdf_becomes_a_file_part_carrying_the_name()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("report.pdf", "application/pdf"), new byte[] { 4, 5 }, AllCaps, InlineCap);

        var data = Assert.IsType<DataContent>(Assert.Single(parts));
        Assert.Equal("application/pdf", data.MediaType);
        Assert.Equal("report.pdf", data.Name);
    }

    [Fact]
    public void Audio_becomes_a_data_content()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("clip.mp3", "audio/mpeg"), new byte[] { 6 }, AllCaps, InlineCap);

        var data = Assert.IsType<DataContent>(Assert.Single(parts));
        Assert.Equal("audio/mpeg", data.MediaType);
    }

    [Fact]
    public void A_text_file_is_inlined_with_a_header()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("notes.txt", "text/plain"), Encoding.UTF8.GetBytes("hello world"), AllCaps, InlineCap);

        var text = Assert.IsType<TextContent>(Assert.Single(parts));
        Assert.Contains("--- file: notes.txt ---", text.Text);
        Assert.Contains("hello world", text.Text);
    }

    [Fact]
    public void A_text_file_is_capped_at_the_configured_byte_limit()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("big.txt", "text/plain"), Encoding.UTF8.GetBytes("0123456789ABCDEFGHIJ"), AllCaps, InlineCap);

        var text = Assert.IsType<TextContent>(Assert.Single(parts));
        Assert.EndsWith("0123456789ABCDEF", text.Text);
    }

    [Fact]
    public void An_unsupported_type_is_not_sent_and_gets_a_placeholder()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("movie.mp4", "video/mp4", 123), new byte[] { 9 }, AllCaps, InlineCap);

        var text = Assert.IsType<TextContent>(Assert.Single(parts));
        Assert.Contains("movie.mp4", text.Text);
        Assert.Contains("not sent to this model", text.Text);
    }

    [Fact]
    public void An_image_the_model_cannot_read_is_not_sent()
    {
        var parts = AttachmentContentBuilder.Build(
            Attachment("cat.png", "image/png", 10), new byte[] { 1 }, Caps(ModelInputModality.Text), InlineCap);

        var text = Assert.IsType<TextContent>(Assert.Single(parts));
        Assert.Contains("not sent to this model", text.Text);
    }

    [Theory]
    [InlineData("image/png", ModelInputModality.Image)]
    [InlineData("application/pdf", ModelInputModality.Pdf)]
    [InlineData("audio/mpeg", ModelInputModality.Audio)]
    [InlineData("audio/wav", ModelInputModality.Audio)]
    [InlineData("text/plain", null)]
    [InlineData("video/mp4", null)]
    public void RequiredModality_maps_the_known_types(string contentType, ModelInputModality? expected) =>
        Assert.Equal(expected, AttachmentContentBuilder.RequiredModality(contentType));
}
