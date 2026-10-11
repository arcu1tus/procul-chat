using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Procul.Api.Configuration;

namespace Procul.Api.Infrastructure;

public static class DbContextExtensions
{
    /// <summary>
    /// Registers the pooled <see cref="ProculDbContext"/> using the connection string from
    /// <c>database.connectionString</c> in <c>config.jsonc</c>.
    /// </summary>
    public static IServiceCollection AddProculDbContext(
        this IServiceCollection services,
        ProculConfig config)
    {
        services.AddDbContextPool<ProculDbContext>(opt =>
            opt.UseNpgsql(config.Database.ConnectionString));
        return services;
    }

    /// <summary>
    /// Ensures the database exists and is up to date by applying any pending EF Core
    /// migrations at startup. Runs on every start (it is idempotent) so the container
    /// manages its own Postgres schema. The only reason to skip is an unset
    /// <c>database.connectionString</c> — the integration tests boot the app without a
    /// database, and the app otherwise connects to Postgres lazily.
    /// </summary>
    public static async Task ApplyProculMigrationsAsync(this WebApplication app)
    {
        var connectionString = app.Services
            .GetRequiredService<ProculConfig>()
            .Database
            .ConnectionString;

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            return;
        }

        await using var scope = app.Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();

        await db.Database.MigrateAsync();

        app.Logger.LogInformation("Applied pending EF Core migrations.");
    }
}
