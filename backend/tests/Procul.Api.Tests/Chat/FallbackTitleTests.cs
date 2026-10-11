using Procul.Api.Chat.V1;

namespace Procul.Api.Tests.Chat;

public class FallbackTitleTests
{
    [Fact]
    public void Uses_the_message_when_it_is_short()
        => Assert.Equal("What is the capital of France?", ChatStreamServiceV1.FallbackTitle("What is the capital of France?"));

    [Fact]
    public void Keeps_only_the_first_line()
        => Assert.Equal("First line", ChatStreamServiceV1.FallbackTitle("First line\nSecond line"));

    [Fact]
    public void Trims_surrounding_whitespace()
        => Assert.Equal("Hello", ChatStreamServiceV1.FallbackTitle("   Hello   "));

    [Fact]
    public void Truncates_a_long_message_with_an_ellipsis()
    {
        var title = ChatStreamServiceV1.FallbackTitle(new string('a', 60));

        Assert.Equal(new string('a', 50) + "…", title);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\n\n")]
    public void Falls_back_to_a_default_when_there_is_no_text(string message)
        => Assert.Equal("New Conversation", ChatStreamServiceV1.FallbackTitle(message));
}
