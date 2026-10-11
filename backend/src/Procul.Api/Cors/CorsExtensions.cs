using Microsoft.AspNetCore.Cors.Infrastructure;

namespace Procul.Api.Cors;

/// <summary>
/// Cross-origin setup for browser clients. Native desktop/mobile clients are not subject to
/// CORS, but a Flutter <em>web</em> build is served from a different origin than the API, so the
/// browser blocks unapproved cross-origin requests before they ever reach the server.
///
/// <para>
/// Allowed origins come from the comma-separated <c>CORS_ALLOWED_ORIGINS</c> setting, e.g.
/// <c>CORS_ALLOWED_ORIGINS=https://app.example.com</c>. In <b>development</b> only, when the
/// setting is unset, any origin is allowed so the Flutter web dev server's ephemeral
/// <c>localhost</c> port keeps working. In every other environment the policy allows <b>no</b>
/// cross-origin request until the setting names the frontend's real origin(s): there is no
/// wildcard in production.
/// </para>
///
/// <para>
/// The API is unauthenticated and cookie-less, so no credentials travel and the policy never
/// enables <c>AllowCredentials</c>.
/// </para>
/// </summary>
public static class CorsExtensions
{
    /// <summary>The policy applied to the API pipeline.</summary>
    public const string PolicyName = "ProculCors";

    /// <summary>Configuration key holding the comma-separated list of allowed browser origins.</summary>
    public const string AllowedOriginsSetting = "CORS_ALLOWED_ORIGINS";

    /// <summary>
    /// Registers the API's CORS policy. See the type remarks for how the origin list is resolved
    /// per environment.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="AllowedOriginsSetting"/> contains a wildcard or a value that is not
    /// an absolute http(s) origin, so a misconfiguration fails fast at startup instead of silently
    /// blocking every browser client.
    /// </exception>
    public static IServiceCollection AddProculCors(
        this IServiceCollection services,
        IConfiguration configuration,
        IHostEnvironment environment)
    {
        var origins = ParseOrigins(configuration[AllowedOriginsSetting]);

        services.AddCors(options => options.AddPolicy(PolicyName, policy =>
        {
            if (origins.Count > 0)
            {
                policy.WithOrigins([.. origins]);
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
    /// production deployment with a missing <see cref="AllowedOriginsSetting"/> is obvious in the
    /// logs instead of surfacing as a mysterious browser failure.
    /// </summary>
    public static IApplicationBuilder UseProculCors(this WebApplication app)
    {
        var origins = ParseOrigins(app.Configuration[AllowedOriginsSetting]);

        if (origins.Count > 0)
        {
            app.Logger.LogInformation(
                "CORS: allowing browser origins {Origins}.", string.Join(", ", origins));
        }
        else if (app.Environment.IsDevelopment())
        {
            app.Logger.LogInformation(
                "CORS: development environment, allowing any browser origin.");
        }
        else
        {
            app.Logger.LogWarning(
                "CORS: {Setting} is not set and the environment is '{Environment}', so all " +
                "cross-origin browser requests will be blocked. Set it to the frontend's " +
                "origin(s), e.g. https://app.example.com.",
                AllowedOriginsSetting,
                app.Environment.EnvironmentName);
        }

        return app.UseCors(PolicyName);
    }

    /// <summary>
    /// Splits, trims, validates and normalizes the configured origins. An empty list means "not
    /// configured" and is resolved by the caller per environment.
    /// </summary>
    private static IReadOnlyList<string> ParseOrigins(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return [];
        }

        var origins = new List<string>();

        foreach (var value in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (value == "*")
            {
                throw new InvalidOperationException(
                    $"{AllowedOriginsSetting} must list explicit origins; a wildcard ('*') is not " +
                    "allowed. Set it to the frontend's origin(s), e.g. https://app.example.com.");
            }

            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
                || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
                || uri.AbsolutePath != "/")
            {
                throw new InvalidOperationException(
                    $"{AllowedOriginsSetting} contains '{value}', which is not a valid origin. " +
                    "Expected an absolute http(s) origin without a path, e.g. https://app.example.com.");
            }

            // CORS origin matching is an exact string comparison, so normalize away a trailing
            // slash and any default port the browser would omit.
            origins.Add(uri.GetLeftPart(UriPartial.Authority));
        }

        return origins;
    }
}
