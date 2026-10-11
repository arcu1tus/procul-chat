namespace Procul.Api.Cors;

/// <summary>
/// Cross-origin setup for browser clients. The native desktop/mobile clients are not subject
/// to CORS, but <c>flutter run -d chrome</c> serves the app from a different origin than the
/// API and the browser blocks unapproved cross-origin requests before they reach the server.
/// </summary>
public static class CorsExtensions
{
    /// <summary>The policy applied to the API pipeline.</summary>
    public const string PolicyName = "ProculCors";

    /// <summary>
    /// Registers the API's CORS policy. Explicit origins are read from the comma-separated
    /// <c>CORS_ALLOWED_ORIGINS</c> setting. When it is unset, development allows any origin so
    /// the Flutter web dev server's ephemeral <c>localhost</c> port works; other environments
    /// deny cross-origin requests unless configured. The API is unauthenticated and cookie-less,
    /// so no credentials need to travel and a wildcard origin is safe in development.
    /// </summary>
    public static IServiceCollection AddProculCors(
        this IServiceCollection services,
        IConfiguration configuration,
        IHostEnvironment environment)
    {
        services.AddCors(options => options.AddPolicy(PolicyName, policy =>
        {
            var origins = configuration["CORS_ALLOWED_ORIGINS"]
                ?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

            if (origins is { Length: > 0 })
            {
                policy.WithOrigins(origins);
            }
            else if (environment.IsDevelopment())
            {
                policy.AllowAnyOrigin();
            }

            // application/json bodies trigger a preflight, and the SSE/PATCH/DELETE verbs
            // (with their headers) must survive it.
            policy.AllowAnyHeader().AllowAnyMethod();
        }));

        return services;
    }
}
