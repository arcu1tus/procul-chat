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
}
