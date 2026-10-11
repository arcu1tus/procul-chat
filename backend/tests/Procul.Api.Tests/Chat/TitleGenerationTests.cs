using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Exercises the model-facing title path without any network or database dependency. The title
/// call never touches the <see cref="ProculDbContext"/>, but a real (in-memory) context is used so
/// the constructor stays honest.
/// </summary>
public class TitleGenerationTests
{
    private static ChatStreamServiceV1 NewService(FakeChatClient client) =>
        new(
            NewDbContext(),
            client,
            McpTestHelpers.DisabledManager(),
            new ChatModelOptions("test/model"),
            NullLogger<ChatStreamServiceV1>.Instance);

    // The title call never touches the context, so an unconfigured one is enough: no provider
    // (and therefore no database) is ever needed.
    private static ProculDbContext NewDbContext() =>
        new(new DbContextOptionsBuilder<ProculDbContext>().Options);

    [Theory]
    [InlineData("France's capital")]
    [InlineData("  France's capital  ")]
    [InlineData("\"France's capital\"")]
    [InlineData("Title: France's capital")]
    [InlineData("France's capital\nHere is why that is the case")]
    public async Task GenerateTitleAsync_normalizes_model_output(string raw)
    {
        var service = NewService(new FakeChatClient(raw));

        var result = await service.GenerateTitleAsync("What is the capital of France?", CancellationToken.None);

        Assert.Equal("France's capital", result.Title);
    }

    [Theory]
    [InlineData("")]              // empty
    [InlineData("   ")]           // whitespace only
    [InlineData("The user is asking about the capital of France")] // meta phrase
    [InlineData("one two three four five six seven eight nine")]   // too many words
    public async Task GenerateTitleAsync_rejects_unusable_output(string raw)
    {
        var service = NewService(new FakeChatClient(raw));

        var result = await service.GenerateTitleAsync("hi", CancellationToken.None);

        Assert.Null(result.Title);
    }

    [Fact]
    public async Task GenerateTitleAsync_falls_back_to_null_when_the_model_throws()
    {
        var service = NewService(new FakeChatClient((_, _, _) =>
            throw new InvalidOperationException("boom")));

        var result = await service.GenerateTitleAsync("hi", CancellationToken.None);

        Assert.Null(result.Title);
    }

    [Fact]
    public async Task GenerateTitleAsync_caps_an_overlong_single_line_title()
    {
        var raw = new string('a', 120);
        var service = NewService(new FakeChatClient(raw));

        var result = await service.GenerateTitleAsync("hi", CancellationToken.None);

        Assert.NotNull(result.Title);
        Assert.True(result.Title!.Length <= ChatStreamServiceV1.MaxTitleLength);
    }
}
