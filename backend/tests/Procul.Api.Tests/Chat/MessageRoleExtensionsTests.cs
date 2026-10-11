using Microsoft.Extensions.AI;
using Procul.Api.Chat;

namespace Procul.Api.Tests.Chat;

public class MessageRoleExtensionsTests
{
    [Theory]
    [InlineData(MessageRole.System, "system")]
    [InlineData(MessageRole.User, "user")]
    [InlineData(MessageRole.Assistant, "assistant")]
    [InlineData(MessageRole.Tool, "tool")]
    public void ToChatRole_maps_every_persisted_role(MessageRole role, string expected)
        => Assert.Equal(expected, role.ToChatRole().Value);

    [Fact]
    public void ToChatRole_throws_for_an_unknown_role()
        => Assert.Throws<ArgumentOutOfRangeException>(() => ((MessageRole)99).ToChatRole());
}
