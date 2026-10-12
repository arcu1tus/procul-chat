using Microsoft.EntityFrameworkCore;
using Procul.Api.Infrastructure;

namespace Procul.Api.Attachments;

/// <summary>
/// Background sweep that enforces the media retention windows. For each category
/// (<see cref="Attachment.SourceUpload"/> / <see cref="Attachment.SourceGenerated"/>) it finds
/// attachments older than the configured window and:
/// <list type="bullet">
/// <item><b>orphaned</b> rows (<see cref="Attachment.MessageId"/> is null — uploaded but never
/// sent, a failed send, or a generated image from a turn that never persisted) are deleted
/// outright (metadata + bytes);</item>
/// <item><b>referenced</b> rows keep their metadata but lose their bytes, so history still shows a
/// "file expired" chip rather than a broken image.</item>
/// </list>
/// Every purge deletes bytes through <see cref="IAttachmentStore"/> first, because S3 objects do
/// not cascade with the metadata rows.
/// </summary>
public sealed class MediaRetentionService(
    IServiceScopeFactory scopeFactory,
    MediaRetentionOptions options,
    ILogger<MediaRetentionService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await DelayAsync(options.InitialDelay, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            await RunSweepAsync(stoppingToken);

            try
            {
                await DelayAsync(options.Interval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task RunSweepAsync(CancellationToken ct)
    {
        try
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
            var store = scope.ServiceProvider.GetRequiredService<IAttachmentStore>();
            await PurgeAsync(db, store, DateTimeOffset.UtcNow, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // A failed sweep is never fatal; the next tick retries.
            logger.LogWarning(ex, "Media retention sweep failed.");
        }
    }

    /// <summary>
    /// Runs one sweep against the supplied context/store. Separated from the loop so tests can
    /// invoke it directly with a seeded database and an in-memory store.
    /// </summary>
    public async Task PurgeAsync(
        ProculDbContext db,
        IAttachmentStore store,
        DateTimeOffset now,
        CancellationToken ct)
    {
        await PurgeCategoryAsync(db, store, Attachment.SourceUpload, options.UploadRetention, now, ct);
        await PurgeCategoryAsync(db, store, Attachment.SourceGenerated, options.GeneratedRetention, now, ct);
    }

    private async Task PurgeCategoryAsync(
        ProculDbContext db,
        IAttachmentStore store,
        string source,
        TimeSpan window,
        DateTimeOffset now,
        CancellationToken ct)
    {
        // A zero window means retention is disabled for this category.
        if (window <= TimeSpan.Zero)
        {
            return;
        }

        var cutoff = now - window;
        var expired = await db.Attachments
            .Where(a => a.Source == source && a.CreatedAt < cutoff)
            .ToListAsync(ct);

        if (expired.Count == 0)
        {
            return;
        }

        // Bytes never cascade (S3 especially), so delete them for every expired row first.
        await store.DeleteBytesAsync(expired, ct);

        // Orphans lose their metadata too; referenced media keeps a metadata-only row.
        var orphans = expired.Where(a => a.MessageId is null).ToList();
        if (orphans.Count > 0)
        {
            db.Attachments.RemoveRange(orphans);
        }

        await db.SaveChangesAsync(ct);

        logger.LogInformation(
            "Media retention: purged {Total} '{Source}' item(s) older than {Window} " +
            "({Orphans} deleted, {Referenced} bytes-only).",
            expired.Count, source, window, orphans.Count, expired.Count - orphans.Count);
    }

    private static async Task DelayAsync(TimeSpan delay, CancellationToken ct)
    {
        if (delay > TimeSpan.Zero)
        {
            await Task.Delay(delay, ct);
        }
    }
}
