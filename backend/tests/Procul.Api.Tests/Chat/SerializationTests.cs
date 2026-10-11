using System.Text.Json;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;

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
}
