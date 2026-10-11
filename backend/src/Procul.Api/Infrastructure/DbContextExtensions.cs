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
    /// Applies any pending EF Core migrations at startup when <c>PROCUL_AUTO_MIGRATE</c>
    /// is enabled. Off by default: the integration tests boot the app without a database,
    /// and the app otherwise connects to Postgres lazily. Intended for single-instance
    /// deployments (e.g. a personal Docker Compose stack); running several replicas that
    /// each migrate concurrently can race.
    /// </summary>
    public static async Task ApplyProculMigrationsAsync(this WebApplication app)
    {
        if (!app.Configuration.GetValue<bool>("PROCUL_AUTO_MIGRATE"))
        {
            return;
        }

        await using var scope = app.Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();

        await db.Database.MigrateAsync();

        app.Logger.LogInformation("Applied pending EF Core migrations.");
    }
}
