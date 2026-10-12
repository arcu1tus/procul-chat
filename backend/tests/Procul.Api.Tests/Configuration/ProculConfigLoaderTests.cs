using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Configuration;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Configuration;

/// <summary>
/// Unit tests for the <c>config.jsonc</c> loader: JSONC tolerance, schema validation, <c>${ENV}</c>
/// interpolation, and every fail-fast domain rule.
/// </summary>
public class ProculConfigLoaderTests
{
    private static readonly string SchemaPath = Path.Combine(AppContext.BaseDirectory, "config.schema.json");

    private static ProculConfig Load(string json, Func<string, string?>? environment = null)
    {
        using var config = TempConfig.Write(json);
        return ProculConfigLoader.Load(
            config.Path, explicitPath: true, environment ?? (_ => null), NullLogger.Instance, SchemaPath);
    }

    private const string MinimalModel =
        """{ "slug": "test/model", "baseUrl": "https://openrouter.ai/api/v1" }""";

    [Fact]
    public void Parses_a_full_config_with_jsonc_comments_and_trailing_commas()
    {
        var config = Load($$"""
            {
              // The single source of truth.
              "$schema": "./config.schema.json",
              "server": { "corsAllowedOrigins": ["https://app.example.com"], "sessionLifetime": "12h" },
              "database": { "connectionString": "Host=db" },
              "attachments": { "storage": "postgres", "maxFileSizeBytes": 1024, "allowedContentTypes": ["image/*"] },
              "models": [
                {
                  "slug": "test/model",
                  "name": "Test",
                  "baseUrl": "https://openrouter.ai/api/v1",
                  "apiKey": "key",
                  "provider": "openrouter",
                  "capabilities": ["text", "image"],
                  "default": true,
                },
              ],
              "titleModel": "test/model",
              "modelHealth": { "enabled": false, "interval": "10m", "timeout": "5s" },
              "mcp": { "enabled": false, "connectTimeout": "30s", "healthInterval": "2m" },
              "mcpServers": {
                "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
              },
            }
            """);

        Assert.Equal("12h", config.Server.SessionLifetime);
        Assert.Equal("Host=db", config.Database.ConnectionString);
        Assert.Equal("postgres", config.Attachments.Storage);
        Assert.Single(config.Models);
        Assert.Equal("test/model", config.Models[0].Slug);
        Assert.True(config.Models[0].Default);
        Assert.Equal("test/model", config.TitleModel);
        Assert.False(config.ModelHealth.Enabled);
        Assert.False(config.Mcp.Enabled);
        Assert.True(config.McpServers.ContainsKey("github"));
    }

    [Fact]
    public void Expands_environment_references_everywhere()
    {
        var config = Load($$"""
            {
              "database": { "connectionString": "${DB}" },
              "models": [
                { "slug": "test/model", "baseUrl": "https://openrouter.ai/api/v1", "apiKey": "${KEY}" }
              ],
              "mcpServers": {
                "github": { "type": "http", "url": "https://api.test/mcp",
                  "headers": { "Authorization": "Bearer ${TOKEN}" } }
              }
            }
            """,
            name => name switch { "DB" => "Host=x", "KEY" => "sk-1", "TOKEN" => "t0ken", _ => null });

        Assert.Equal("Host=x", config.Database.ConnectionString);
        Assert.Equal("sk-1", config.Models[0].ApiKey);
        Assert.Equal("Bearer t0ken", config.McpServers["github"].Headers!["Authorization"]);
    }

    [Fact]
    public void An_unresolved_environment_reference_is_fatal_and_names_the_variable()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [ { "slug": "test/model", "baseUrl": "https://x/v1", "apiKey": "${MISSING_KEY}" } ] }
            """));

        Assert.Contains("MISSING_KEY", ex.Message);
    }

    [Fact]
    public void A_missing_config_file_is_fatal()
    {
        var missing = Path.Combine(Path.GetTempPath(), $"procul-missing-{Guid.NewGuid():N}.jsonc");

        var ex = Assert.Throws<InvalidOperationException>(() => ProculConfigLoader.Load(
            missing, explicitPath: false, _ => null, NullLogger.Instance, SchemaPath));

        Assert.Contains("config.jsonc", ex.Message);
    }

    [Theory]
    [InlineData("""{ "models": "nope" }""")]                     // wrong type
    [InlineData("""{}""")]                                       // missing required 'models'
    [InlineData("""{ "models": [], "bogus": 1 }""")]             // unknown property + zero models
    public void Schema_failures_are_fatal(string json)
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load(json));
        Assert.Contains("schema", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Zero_models_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load("""{ "models": [] }"""));

    [Fact]
    public void An_unknown_property_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [ {{MinimalModel}} ], "unexpected": true }
            """));

    [Fact]
    public void Two_defaults_are_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [
                { "slug": "a", "baseUrl": "https://openrouter.ai/api/v1", "default": true },
                { "slug": "b", "baseUrl": "https://openrouter.ai/api/v1", "default": true }
            ] }
            """));

        Assert.Contains("default", ex.Message);
    }

    [Fact]
    public void A_duplicate_slug_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [
                { "slug": "dup", "baseUrl": "https://openrouter.ai/api/v1" },
                { "slug": "dup", "baseUrl": "https://openrouter.ai/api/v1" }
            ] }
            """));

        Assert.Contains("duplicate slug", ex.Message);
    }

    [Fact]
    public void A_non_absolute_base_url_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [ { "slug": "m", "baseUrl": "not-a-url" } ] }
            """));

        Assert.Contains("baseUrl", ex.Message);
    }

    [Fact]
    public void An_unknown_provider_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "models": [ { "slug": "m", "baseUrl": "https://x/v1", "provider": "weird" } ] }
            """));

    [Fact]
    public void A_bad_attachment_storage_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "attachments": { "storage": "ftp" }, "models": [ {{MinimalModel}} ] }
            """));

        Assert.Contains("storage", ex.Message);
    }

    [Fact]
    public void S3_storage_without_a_section_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "attachments": { "storage": "s3" }, "models": [ {{MinimalModel}} ] }
            """));

    [Fact]
    public void A_title_model_referencing_an_unknown_slug_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "titleModel": "nope", "models": [ {{MinimalModel}} ] }
            """));

        Assert.Contains("titleModel", ex.Message);
    }

    [Fact]
    public void A_malformed_duration_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "server": { "sessionLifetime": "soon" }, "models": [ {{MinimalModel}} ] }
            """));

    [Fact]
    public void The_example_loads_with_all_secrets_resolved()
    {
        var example = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "config.jsonc.example"));

        var config = Load(example, name => name switch
        {
            "DB_CONNECTION_STRING" => "Host=x",
            "S3_BUCKET" => "bucket",
            "S3_REGION" => "region",
            "S3_ENDPOINT" => "http://s3.local",
            "S3_ACCESS_KEY" => "access",
            "S3_SECRET_KEY" => "secret",
            "OPENROUTER_KEY" => "sk-1",
            "GITHUB_MCP_TOKEN" => "token",
            _ => null,
        });

        Assert.Single(config.Models);
        Assert.Equal("openrouter/free", config.Models[0].Slug);
        Assert.True(config.Models[0].Default);
        Assert.Equal("openrouter/free", config.TitleModel);
    }

    [Fact]
    public void The_image_generation_section_is_parsed()
    {
        var config = Load($$"""
            {
              "models": [ {{MinimalModel}} ],
              "imageGeneration": {
                "enabled": true,
                "provider": "openai-compatible",
                "baseUrl": "https://images.example/v1",
                "apiKey": "${IMG_KEY}",
                "model": "some/image-model",
                "defaultSize": "1024x1024",
                "defaultAspectRatio": "1:1",
                "maxReferenceImages": 3,
                "timeout": "90s",
                "retention": "7d"
              }
            }
            """,
            name => name == "IMG_KEY" ? "sk-img" : null);

        Assert.True(config.ImageGeneration.Enabled);
        Assert.Equal("openai-compatible", config.ImageGeneration.Provider);
        Assert.Equal("some/image-model", config.ImageGeneration.Model);

        var options = ImageGenerationOptions.FromConfig(config);
        Assert.True(options.Enabled);
        Assert.Equal("https://images.example/v1", options.BaseUrl);
        Assert.Equal("sk-img", options.ApiKey);
        Assert.Equal(3, options.MaxReferenceImages);
        Assert.Equal(TimeSpan.FromSeconds(90), options.Timeout);
        Assert.Equal(TimeSpan.FromDays(7), options.Retention);
    }

    [Fact]
    public void Generated_media_inherits_the_upload_retention_when_unset()
    {
        var config = Load($$"""
            { "attachments": { "retention": "10d" }, "models": [ {{MinimalModel}} ] }
            """);

        Assert.Equal(TimeSpan.FromDays(10), AttachmentOptions.FromConfig(config).Retention);
        Assert.Equal(TimeSpan.FromDays(10), ImageGenerationOptions.FromConfig(config).Retention);
    }

    [Fact]
    public void A_zero_retention_keeps_media_forever()
    {
        var config = Load($$"""
            { "attachments": { "retention": "0" }, "models": [ {{MinimalModel}} ] }
            """);

        Assert.Equal(TimeSpan.Zero, AttachmentOptions.FromConfig(config).Retention);
        Assert.Equal(TimeSpan.Zero, DurationParser.ParseRetention("0", TimeSpan.FromDays(14), "x"));
    }

    [Fact]
    public void A_malformed_retention_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "attachments": { "retention": "soon" }, "models": [ {{MinimalModel}} ] }
            """));

        Assert.Contains("retention", ex.Message);
    }

    [Fact]
    public void An_unknown_image_provider_is_fatal() =>
        Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "imageGeneration": { "provider": "weird" }, "models": [ {{MinimalModel}} ] }
            """));

    [Fact]
    public void Enabling_image_generation_without_a_model_is_fatal()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Load($$"""
            { "imageGeneration": { "enabled": true }, "models": [ {{MinimalModel}} ] }
            """));

        Assert.Contains("model", ex.Message);
    }
}
