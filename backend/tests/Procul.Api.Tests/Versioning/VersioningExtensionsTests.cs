using Asp.Versioning;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Procul.Api.Versioning;

namespace Procul.Api.Tests.Versioning;

public class VersioningExtensionsTests
{
    [Fact]
    public void Defaults_to_v1_with_url_segment_versioning()
    {
        var services = new ServiceCollection();
        services.AddProculApiVersioning();

        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<ApiVersioningOptions>>().Value;

        Assert.Equal(ApiVersions.V1, options.DefaultApiVersion);
        Assert.False(options.AssumeDefaultVersionWhenUnspecified);
        Assert.True(options.ReportApiVersions);
        Assert.IsType<UrlSegmentApiVersionReader>(options.ApiVersionReader);
    }
}
