using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Procul.Api.Configuration;

namespace Procul.Api.Cors;

/// <summary>
/// Cross-origin setup for browser clients. Native desktop/mobile clients are not subject to
/// CORS, but a Flutter <em>web</em> build is served from a different origin than the API, so the
/// browser blocks unapproved cross-origin requests before they ever reach the server.
///
/// <para>
/// Allowed origins come from <c>server.corsAllowedOrigins</c> in <c>config.jsonc</c>. In
/// <b>development</b> only, when the list is empty, any origin is allowed so the Flutter web dev
/// server's ephemeral <c>localhost</c> port keeps working. In every other environment the policy
/// allows <b>no</b> cross-origin request until the config names the frontend's real origin(s):
/// there is no wildcard in production.
/// </para>
///
/// <para>
/// The API is cookie-less (clients send a bearer token), so no credentials travel and the policy
/// never enables <c>AllowCredentials</c>.
/// </para>
/// </summary>
public static class CorsExtensions
{
    /// <summary>The policy applied to the API pipeline.</summary>
    public const string PolicyName = "ProculCors";

    /// <summary>
    /// Registers the API's CORS policy from the validated <see cref="CorsOptions"/>. See the type
    /// remarks for how the origin list is resolved per environment.
    /// </summary>
    public static IServiceCollection AddProculCors(
        this IServiceCollection services,
        ProculConfig config,
        IHostEnvironment environment)
    {
        var options = CorsOptions.FromConfig(config);
        services.AddSingleton(options);

        services.AddCors(cors => cors.AddPolicy(PolicyName, policy =>
        {
            if (options.AllowedOrigins.Count > 0)
            {
                policy.WithOrigins([.. options.AllowedOrigins]);
            }
            else if (environment.IsDevelopment())
            {
                // Development only: the Flutter web dev server uses an ephemeral localhost port,
                // so pinning an origin is impractical. Never reached in production.
                policy.AllowAnyOrigin();
            }

            // application/json bodies trigger a preflight, and the SSE/PATCH/DELETE verbs
            // (with their headers) must survive it.
            policy.AllowAnyHeader().AllowAnyMethod();
        }));

        return services;
    }

    /// <summary>
    /// Applies the <see cref="PolicyName"/> CORS policy and logs how it was configured, so a
    /// production deployment with no configured origins is obvious in the logs instead of
    /// surfacing as a mysterious browser failure.
    /// </summary>
    public static IApplicationBuilder UseProculCors(this WebApplication app)
    {
        var options = app.Services.GetRequiredService<CorsOptions>();

        if (options.AllowedOrigins.Count > 0)
        {
            app.Logger.LogInformation(
                "CORS: allowing browser origins {Origins}.", string.Join(", ", options.AllowedOrigins));
        }
        else if (app.Environment.IsDevelopment())
        {
            app.Logger.LogInformation(
                "CORS: development environment, allowing any browser origin.");
        }
        else
        {
            app.Logger.LogWarning(
                "CORS: no origins are configured in 'server.corsAllowedOrigins' and the environment " +
                "is '{Environment}', so all cross-origin browser requests will be blocked. Set it to " +
                "the frontend's origin(s), e.g. https://app.example.com.",
                app.Environment.EnvironmentName);
        }

        return app.UseCors(PolicyName);
    }
}
