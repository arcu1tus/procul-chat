using Procul.Api.Mcp;

namespace Procul.Api.Configuration;

/// <summary>
/// The root shape of <c>config.jsonc</c>: the single source of truth for the backend. Secrets
/// are not stored here — string values may reference environment variables as <c>${VAR}</c>,
/// which <see cref="ProculConfigLoader"/> resolves at startup.
/// </summary>
public sealed class ProculConfig
{
    /// <summary>HTTP server settings (CORS origins, session lifetime).</summary>
    public ServerConfig Server { get; set; } = new();

    /// <summary>Database connection settings.</summary>
    public DatabaseConfig Database { get; set; } = new();

    /// <summary>Attachment upload settings (consumed in a later plan).</summary>
    public AttachmentConfig Attachments { get; set; } = new();

    /// <summary>The configured chat models. At least one is required.</summary>
    public List<ChatModelConfig> Models { get; set; } = [];

    /// <summary>The slug used for the title call, or null to use the conversation's model.</summary>
    public string? TitleModel { get; set; }

    /// <summary>Model health-probe settings.</summary>
    public ModelHealthConfig ModelHealth { get; set; } = new();

    /// <summary>MCP client settings (master switch + timeouts).</summary>
    public McpSettingsConfig Mcp { get; set; } = new();

    /// <summary>Configured MCP servers, keyed by the operator's chosen name.</summary>
    public Dictionary<string, McpServerConfig> McpServers { get; set; } = new();
}

/// <summary>HTTP server settings.</summary>
public sealed class ServerConfig
{
    /// <summary>Browser origins allowed to call the API. Empty means "not configured".</summary>
    public List<string> CorsAllowedOrigins { get; set; } = [];

    /// <summary>Session-token lifetime, e.g. <c>30d</c>. Null uses the default.</summary>
    public string? SessionLifetime { get; set; }
}

/// <summary>Database settings.</summary>
public sealed class DatabaseConfig
{
    /// <summary>The Postgres connection string. Null leaves the database unconfigured.</summary>
    public string? ConnectionString { get; set; }
}

/// <summary>Attachment upload settings.</summary>
public sealed class AttachmentConfig
{
    /// <summary>Where attachment bytes are stored: <c>postgres</c> or <c>s3</c>.</summary>
    public string Storage { get; set; } = "postgres";

    /// <summary>Largest attachment accepted, in bytes.</summary>
    public long MaxFileSizeBytes { get; set; } = 20 * 1024 * 1024;

    /// <summary>
    /// Allowed content-type patterns (e.g. <c>image/*</c>). An empty list rejects every upload,
    /// so set it explicitly (see <c>config.jsonc.example</c> for the recommended defaults).
    /// </summary>
    public List<string> AllowedContentTypes { get; set; } = [];

    /// <summary>
    /// Whether earlier turns re-send an attachment's bytes every time, or only a short text note.
    /// <c>true</c> (the default) re-sends, so a model chosen later can still read earlier files
    /// (a capability the current model lacks still degrades to a note). Set <c>false</c> to keep
    /// only the newest user turn carrying the bytes and bound the prompt size.
    /// </summary>
    public bool ResendHistory { get; set; } = true;

    /// <summary>Cap, in bytes, on how much of a <c>text/*</c> file is inlined into the prompt.</summary>
    public long TextInlineMaxBytes { get; set; } = 256 * 1024;

    /// <summary>S3-compatible storage settings; required when <see cref="Storage"/> is <c>s3</c>.</summary>
    public S3AttachmentConfig? S3 { get; set; }
}

/// <summary>S3-compatible object-storage settings.</summary>
public sealed class S3AttachmentConfig
{
    public string? Bucket { get; set; }
    public string? Region { get; set; }

    /// <summary>Custom endpoint for MinIO / S3-compatible services. Omit for AWS.</summary>
    public string? ServiceUrl { get; set; }

    public bool ForcePathStyle { get; set; }
    public string? AccessKey { get; set; }
    public string? SecretKey { get; set; }
}

/// <summary>One entry under <c>models</c>.</summary>
public sealed class ChatModelConfig
{
    /// <summary>The model id sent on the wire; also the registry key. Required.</summary>
    public string? Slug { get; set; }

    /// <summary>Human-readable name. Falls back to the slug when omitted.</summary>
    public string? Name { get; set; }

    public string? Description { get; set; }

    /// <summary>API key. Supports <c>${ENV_VAR}</c>. Never returned by the API.</summary>
    public string? ApiKey { get; set; }

    /// <summary>The provider base URL, e.g. <c>https://openrouter.ai/api/v1</c>. Required.</summary>
    public string? BaseUrl { get; set; }

    /// <summary>Provider kind: <c>openrouter</c> or <c>openai-compatible</c>. Auto-detected when omitted.</summary>
    public string? Provider { get; set; }

    /// <summary>Declared input modalities, e.g. <c>["text","image"]</c>. Discovered when omitted.</summary>
    public List<string>? Capabilities { get; set; }

    /// <summary>Marks the default model. At most one model may set this.</summary>
    public bool Default { get; set; }

    /// <summary>Whether to probe this model at startup / on the idle cadence.</summary>
    public bool HealthCheck { get; set; } = true;

    /// <summary>Whether to discover capabilities from the provider's <c>/models</c> endpoint.</summary>
    public bool DiscoverCapabilities { get; set; } = true;

    /// <summary>Upper bound on output tokens, or null for the provider default.</summary>
    public int? MaxOutputTokens { get; set; }
}

/// <summary>Model health-probe settings.</summary>
public sealed class ModelHealthConfig
{
    /// <summary>Master switch for the catalog/health service.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Idle re-probe cadence. Defaults to <c>30m</c>.</summary>
    public string? Interval { get; set; }

    /// <summary>Per-probe budget. Defaults to <c>10s</c>.</summary>
    public string? Timeout { get; set; }

    /// <summary>The prompt sent to confirm a model is alive.</summary>
    public string? ProbePrompt { get; set; }

    /// <summary>Output-token cap for a probe. Defaults to <c>5</c>.</summary>
    public int MaxOutputTokens { get; set; } = 5;
}

/// <summary>MCP client settings.</summary>
public sealed class McpSettingsConfig
{
    /// <summary>Master switch. When false the servers are never connected.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Per-server connect + tool-discovery budget. Defaults to <c>15s</c>.</summary>
    public string? ConnectTimeout { get; set; }

    /// <summary>Background ping/reconnect cadence. Defaults to <c>60s</c>.</summary>
    public string? HealthInterval { get; set; }
}
