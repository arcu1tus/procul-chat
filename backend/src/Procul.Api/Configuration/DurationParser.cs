using System.Globalization;

namespace Procul.Api.Configuration;

/// <summary>
/// Parses durations made of one or more <c>&lt;number&gt;&lt;unit&gt;</c> segments, where the
/// unit is <c>d</c>, <c>h</c>, <c>m</c> or <c>s</c> (e.g. <c>30d</c>, <c>12h</c>, <c>1h30m</c>).
/// Shared by the session lifetime and the MCP timeouts so every setting accepts the same syntax.
/// </summary>
internal static class DurationParser
{
    /// <summary>
    /// Parses <paramref name="raw"/> into a positive <see cref="TimeSpan"/>. A blank value
    /// yields <paramref name="defaultValue"/>; anything malformed throws, naming
    /// <paramref name="settingName"/> so a misconfigured deployment fails fast.
    /// </summary>
    public static TimeSpan Parse(string? raw, TimeSpan defaultValue, string settingName)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return defaultValue;
        }

        var value = raw.Trim();
        var total = TimeSpan.Zero;
        var index = 0;

        while (index < value.Length)
        {
            var start = index;
            while (index < value.Length && char.IsAsciiDigit(value[index]))
            {
                index++;
            }

            if (index == start || index >= value.Length)
            {
                throw Malformed(raw, settingName);
            }

            if (!long.TryParse(value.AsSpan(start, index - start), NumberStyles.None, CultureInfo.InvariantCulture, out var amount))
            {
                throw Malformed(raw, settingName);
            }

            var unit = char.ToLowerInvariant(value[index]);
            index++;

            total += unit switch
            {
                'd' => TimeSpan.FromDays(amount),
                'h' => TimeSpan.FromHours(amount),
                'm' => TimeSpan.FromMinutes(amount),
                's' => TimeSpan.FromSeconds(amount),
                _ => throw Malformed(raw, settingName),
            };
        }

        if (total <= TimeSpan.Zero)
        {
            throw Malformed(raw, settingName);
        }

        return total;
    }

    private static InvalidOperationException Malformed(string? raw, string settingName) =>
        new(
            $"{settingName} value '{raw}' is not a valid duration. Use a number followed " +
            "by a unit: d (days), h (hours), m (minutes) or s (seconds), e.g. 30d, 12h or 1h30m.");
}
