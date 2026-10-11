using Asp.Versioning;

namespace Procul.Api.Versioning;

public static class VersioningExtensions
{
    public static IServiceCollection AddProculApiVersioning(this IServiceCollection services)
    {
        services.AddApiVersioning(o =>
        {
            o.DefaultApiVersion = ApiVersions.V1;
            o.AssumeDefaultVersionWhenUnspecified = false;
            o.ReportApiVersions = true;
            o.ApiVersionReader = new UrlSegmentApiVersionReader();
        });
        return services;
    }
}