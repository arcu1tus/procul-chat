using System.Text.Json;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Usage.V1;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Locks in the wire contract the Flutter client depends on: camelCase property names, the
/// integer <see cref="MessageRole"/> ordinal, and the <c>type</c> discriminator carried inside the
/// SSE <c>value</c> envelope.
/// </summary>
public class SerializationTests
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    [Fact]
    public void Request_dtos_serialize_as_camelCase()
    {
        var json = JsonSerializer.Serialize(new CreateConversationRequestV1("hi"), Web);

        Assert.Equal("{\"initialMessage\":\"hi\"}", json);
    }

    [Fact]
    public void Message_role_serializes_as_its_ordinal()
    {
        var message = new ConversationMessageV1(
            Guid.NewGuid(), Guid.NewGuid(), "hi", MessageRole.User, DateTimeOffset.UnixEpoch);

        var json = JsonSerializer.Serialize(message, Web);

        Assert.Contains("\"messageRole\":1", json);
    }

    [Fact]
    public void Sse_events_carry_the_type_discriminator_inside_the_value_envelope()
    {
        var evt = new ChatStreamEventV1.Token(new ChatStreamTokenV1("Hello"));

        var json = JsonSerializer.Serialize<object>(evt, Web);

        Assert.Equal("{\"value\":{\"content\":\"Hello\",\"type\":\"token\"}}", json);
    }

    [Fact]
    public void The_usage_sse_event_serializes_under_the_value_envelope()
    {
        var evt = new ChatStreamEventV1.Usage(new ChatStreamUsageV1(11, 6, 2, 17));

        var json = JsonSerializer.Serialize<object>(evt, Web);

        Assert.Equal(
            "{\"value\":{\"inputTokens\":11,\"outputTokens\":6,\"cachedInputTokens\":2,\"totalTokens\":17,\"type\":\"usage\"}}",
            json);
    }

    [Fact]
    public void The_image_sse_event_serializes_under_the_value_envelope()
    {
        var id = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var evt = new ChatStreamEventV1.Image(new ChatStreamImageV1(id, "cat.png", "image/png"));

        var json = JsonSerializer.Serialize<object>(evt, Web);

        Assert.Equal(
            "{\"value\":{\"attachmentId\":\"11111111-1111-1111-1111-111111111111\"," +
            "\"fileName\":\"cat.png\",\"contentType\":\"image/png\",\"type\":\"image\"}}",
            json);
    }

    [Fact]
    public void Usage_dtos_serialize_as_camelCase()
    {
        var response = new GetUsageResponseV1(
            new UsageTotalsV1(1, 2, 3, 4, 5),
            [new UsageDayV1("2026-10-11", 1, 2, 3, 4, 5)],
            [new UsageModelV1("test/model", 1, 2, 3, 4, 5)]);

        var json = JsonSerializer.Serialize(response, Web);

        Assert.Contains("\"lifetime\":", json);
        Assert.Contains("\"inputTokens\":1", json);
        Assert.Contains("\"cachedInputTokens\":3", json);
        Assert.Contains("\"totalTokens\":4", json);
        Assert.Contains("\"date\":\"2026-10-11\"", json);
        Assert.Contains("\"model\":\"test/model\"", json);
    }
}
