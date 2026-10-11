using Microsoft.EntityFrameworkCore;

namespace Procul.Api.Infrastructure;

public static class DbContextExtensions
{
    /// <summary>
    /// Registers the pooled <see cref="ProculDbContext"/> using the
    /// <c>ConnectionStrings:ChatContext</c> Postgres connection string.
    /// </summary>
    public static IServiceCollection AddProculDbContext(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddDbContextPool<ProculDbContext>(opt =>
            opt.UseNpgsql(configuration.GetConnectionString("ChatContext")));
        return services;
    }

    /// <summary>
    /// Ensures the database exists and is up to date by applying any pending EF Core
    /// migrations at startup. Runs on every start (it is idempotent) so the container
    /// manages its own Postgres schema. The only reason to skip is a missing
    /// <c>ConnectionStrings:ChatContext</c> — the integration tests boot the app without a
    /// database, and the app otherwise connects to Postgres lazily.
    /// </summary>
    public static async Task ApplyProculMigrationsAsync(this WebApplication app)
    {
        if (string.IsNullOrWhiteSpace(app.Configuration.GetConnectionString("ChatContext")))
        {
            return;
        }

        await using var scope = app.Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();

        await db.Database.MigrateAsync();

        app.Logger.LogInformation("Applied pending EF Core migrations.");
    }
}
