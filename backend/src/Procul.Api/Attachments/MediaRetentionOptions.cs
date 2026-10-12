using Procul.Api.Configuration;

namespace Procul.Api.Attachments;

/// <summary>
/// The retention windows that drive <see cref="MediaRetentionService"/>. Derived from
/// <c>attachments.retention</c> (uploads) and <c>imageGeneration.retention</c> (generated/shown
/// images); both default to <c>14d</c>, and a <see cref="TimeSpan.Zero"/> window disables retention
/// for that category (keep media forever).
/// </summary>
public sealed class MediaRetentionOptions
{
    /// <summary>Age limit for user uploads.</summary>
    public required TimeSpan UploadRetention { get; init; }

    /// <summary>Age limit for generated/shown images.</summary>
    public required TimeSpan GeneratedRetention { get; init; }

    /// <summary>How often the background sweep runs.</summary>
    public required TimeSpan Interval { get; init; }

    /// <summary>How long after startup the first sweep runs (gives the app time to come up).</summary>
    public required TimeSpan InitialDelay { get; init; }

    /// <summary>Builds the options from the validated config.</summary>
    public static MediaRetentionOptions FromConfig(ProculConfig config)
    {
        var upload = DurationParser.ParseRetention(
            config.Attachments.Retention, TimeSpan.FromDays(14), "attachments.retention");

        var generated = string.IsNullOrWhiteSpace(config.ImageGeneration.Retention)
            ? upload
            : DurationParser.ParseRetention(
                config.ImageGeneration.Retention, TimeSpan.FromDays(14), "imageGeneration.retention");

        return new MediaRetentionOptions
        {
            UploadRetention = upload,
            GeneratedRetention = generated,
            Interval = TimeSpan.FromHours(1),
            InitialDelay = TimeSpan.FromMinutes(5),
        };
    }
}
