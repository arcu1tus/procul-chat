using System.ComponentModel;
using Microsoft.Extensions.AI;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// The <c>get_current_time</c> tool: lets the model read the wall clock instead of guessing.
/// </summary>
internal static class TimeTool
{
    /// <summary>The <c>get_current_time</c> tool, exposed to the model via <see cref="AgentTools.All"/>.</summary>
    public static readonly AIFunction CurrentTime =
        AIFunctionFactory.Create(GetCurrentTime, "get_current_time");

    [Description("Returns the current date and time in ISO-8601.")]
    private static string GetCurrentTime(
        [Description("Optional UTC offset in minutes (e.g. 120 for UTC+2). Defaults to 0 (UTC).")]
        int? utcOffsetMinutes = null)
        // InvariantGlobalization is enabled in the csproj, so a named IANA time zone would be
        // unreliable. Accept a numeric UTC offset instead.
        => DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromMinutes(utcOffsetMinutes ?? 0))
               .ToString("yyyy-MM-dd'T'HH:mm:sszzz");
}
