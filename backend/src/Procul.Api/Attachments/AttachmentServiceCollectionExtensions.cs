using Amazon.S3;
using Procul.Api.Configuration;

namespace Procul.Api.Attachments;

/// <summary>Wires the configured attachment store (Postgres or S3) into DI.</summary>
public static class AttachmentServiceCollectionExtensions
{
    /// <summary>
    /// Registers <see cref="IAttachmentStore"/> according to <c>attachments.storage</c>. The store
    /// is scoped because the Postgres implementation shares the request's <c>ProculDbContext</c>;
    /// the S3 implementation resolves a singleton <see cref="IAmazonS3"/> (overridable in tests).
    /// </summary>
    public static IServiceCollection AddProculAttachments(
        this IServiceCollection services,
        ProculConfig config)
    {
        var options = AttachmentOptions.FromConfig(config);

        if (string.Equals(options.Storage, "s3", StringComparison.OrdinalIgnoreCase))
        {
            services.AddSingleton<IAmazonS3>(_ => S3AttachmentStore.CreateClient(options));
            services.AddScoped<IAttachmentStore, S3AttachmentStore>();
        }
        else
        {
            services.AddScoped<IAttachmentStore, PostgresAttachmentStore>();
        }

        return services;
    }
}
