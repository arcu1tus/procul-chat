using Procul.Api.Configuration;

namespace Procul.Api.Chat.Models;

/// <summary>
/// Model health-probe settings, derived from <see cref="ProculConfig"/> at startup. The catalog
/// service probes each model once at startup (unless opted out) and re-probes only models with no
/// real traffic in the last <see cref="Interval"/>.
/// </summary>
public sealed class ModelHealthOptions
{
    /// <summary>Cadence used when <c>modelHealth.interval</c> is unset.</summary>
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromMinutes(30);

    /// <summary>Per-probe budget used when <c>modelHealth.timeout</c> is unset.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);

    /// <summary>Probe prompt used when <c>modelHealth.probePrompt</c> is unset.</summary>
    public const string DefaultProbePrompt = "Reply with the single word: alive";

    /// <summary>Output-token cap used when <c>modelHealth.maxOutputTokens</c> is unset.</summary>
    public const int DefaultMaxOutputTokens = 5;

    /// <summary>Master switch for the catalog/health service.</summary>
    public required bool Enabled { get; init; }

    /// <summary>Idle re-probe cadence.</summary>
    public required TimeSpan Interval { get; init; }

    /// <summary>Per-probe budget.</summary>
    public required TimeSpan Timeout { get; init; }

    /// <summary>The prompt sent to confirm a model is alive.</summary>
    public required string ProbePrompt { get; init; }

    /// <summary>Output-token cap for a probe.</summary>
    public required int MaxOutputTokens { get; init; }

    /// <summary>Builds the options from the validated config.</summary>
    public static ModelHealthOptions FromConfig(ProculConfig config) => new()
    {
        Enabled = config.ModelHealth.Enabled,
        Interval = DurationParser.Parse(
            config.ModelHealth.Interval, DefaultInterval, "modelHealth.interval"),
        Timeout = DurationParser.Parse(
            config.ModelHealth.Timeout, DefaultTimeout, "modelHealth.timeout"),
        ProbePrompt = string.IsNullOrWhiteSpace(config.ModelHealth.ProbePrompt)
            ? DefaultProbePrompt
            : config.ModelHealth.ProbePrompt!,
        MaxOutputTokens = config.ModelHealth.MaxOutputTokens > 0
            ? config.ModelHealth.MaxOutputTokens
            : DefaultMaxOutputTokens,
    };
}
