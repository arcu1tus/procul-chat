using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Json.Schema;

namespace Procul.Api.Configuration;

/// <summary>
/// Loads, validates and secret-resolves <c>config.jsonc</c> — the single source of truth for the
/// backend. The pipeline is: locate the file, parse JSONC, validate against
/// <c>config.schema.json</c>, deserialize, expand every <c>${ENV_VAR}</c> reference, then run
/// fail-fast domain validation. Any problem aborts startup so a misconfigured deployment never
/// runs half-configured.
/// </summary>
internal static class ProculConfigLoader
{
    /// <summary>Environment variable locating the config file.</summary>
    public const string ConfigPathSetting = "PROCUL_CONFIG_PATH";

    /// <summary>The config file looked up next to the app when no path is set.</summary>
    public const string DefaultConfigPath = "config.jsonc";

    /// <summary>The JSON Schema file shipped next to the app.</summary>
    public const string DefaultSchemaPath = "config.schema.json";

    private static readonly JsonSerializerOptions DeserializeOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private static readonly JsonDocumentOptions DocumentOptions = new()
    {
        CommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    private static readonly JsonNodeOptions NodeOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private static readonly Regex EnvReference = new(
        @"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", RegexOptions.Compiled);

    private static readonly HashSet<string> AllowedProviders =
        new(StringComparer.OrdinalIgnoreCase) { "openrouter", "openai-compatible" };

    private static readonly HashSet<string> AllowedCapabilities =
        new(StringComparer.OrdinalIgnoreCase) { "text", "image", "audio", "video", "pdf" };

    private static readonly HashSet<string> AllowedStorage =
        new(StringComparer.OrdinalIgnoreCase) { "postgres", "s3" };

    private static readonly object SchemaLock = new();
    private static JsonSchema? _schema;

    /// <summary>
    /// Locates the config via <see cref="ConfigPathSetting"/> (else <c>config.jsonc</c> next to
    /// the app) and loads it. Environment references resolve from configuration first (so
    /// integration tests can inject them) and the process environment second.
    /// </summary>
    public static ProculConfig Load(IConfiguration configuration, ILogger logger)
    {
        var rawPath = configuration[ConfigPathSetting];
        var explicitPath = !string.IsNullOrWhiteSpace(rawPath);
        var path = explicitPath ? rawPath!.Trim() : DefaultConfigPath;
        var environment = (string name) =>
            configuration[name] ?? Environment.GetEnvironmentVariable(name);
        var schemaPath = Path.Combine(AppContext.BaseDirectory, DefaultSchemaPath);

        return Load(path, explicitPath, environment, logger, schemaPath);
    }

    /// <summary>The explicit-path entry point used by tests and by <see cref="Load(IConfiguration, ILogger)"/>.</summary>
    internal static ProculConfig Load(
        string path,
        bool explicitPath,
        Func<string, string?> environment,
        ILogger logger,
        string schemaPath)
    {
        if (!File.Exists(path))
        {
            throw new InvalidOperationException(
                explicitPath
                    ? $"{ConfigPathSetting} points at '{path}', which does not exist."
                    : $"No config file found at '{path}'. Procul requires a config.jsonc " +
                      "(at least one model); copy config.jsonc.example to get started.");
        }

        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (IOException ex)
        {
            throw new InvalidOperationException($"Could not read config file '{path}': {ex.Message}", ex);
        }

        JsonElement element;
        try
        {
            using var document = JsonDocument.Parse(text, DocumentOptions);
            element = document.RootElement.Clone();
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"Config file '{path}' is not valid JSON/JSONC: {ex.Message}", ex);
        }

        ValidateAgainstSchema(element, path, schemaPath);

        JsonNode node;
        try
        {
            node = JsonNode.Parse(text, NodeOptions, DocumentOptions)
                ?? throw new InvalidOperationException($"Config file '{path}' is empty.");
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"Config file '{path}' is not valid JSON/JSONC: {ex.Message}", ex);
        }

        ExpandEnvironmentReferences(node, environment, path);

        ProculConfig config;
        try
        {
            config = node.Deserialize<ProculConfig>(DeserializeOptions)
                ?? throw new InvalidOperationException($"Config file '{path}' is empty.");
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"Config file '{path}' could not be deserialized: {ex.Message}", ex);
        }

        ValidateDomain(config, logger);
        return config;
    }

    private static void ValidateAgainstSchema(JsonElement element, string path, string schemaPath)
    {
        JsonSchema schema;
        lock (SchemaLock)
        {
            if (_schema is null)
            {
                if (!File.Exists(schemaPath))
                {
                    throw new InvalidOperationException(
                        $"JSON schema file '{schemaPath}' was not found next to the application.");
                }

                _schema = JsonSchema.FromText(File.ReadAllText(schemaPath));
            }

            schema = _schema;
        }

        var results = schema.Evaluate(element, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (results.IsValid)
        {
            return;
        }

        var errors = new List<string>();
        CollectErrors(results, errors);

        throw new InvalidOperationException(
            $"Config file '{path}' failed schema validation:\n  - " +
            string.Join("\n  - ", errors.Count > 0 ? errors : ["(no details)"]));
    }

    private static void CollectErrors(EvaluationResults result, List<string> errors)
    {
        if (result.Errors is { Count: > 0 } resultErrors)
        {
            foreach (var message in resultErrors.Values)
            {
                errors.Add($"{result.InstanceLocation}: {message}");
            }
        }

        if (result.Details is { Count: > 0 } details)
        {
            foreach (var detail in details)
            {
                CollectErrors(detail, errors);
            }
        }
    }

    /// <summary>
    /// Recursively replaces <c>${VAR}</c> references in every string value. A reference to an
    /// unset variable is fatal and names the variable, so a missing secret is obvious at startup.
    /// </summary>
    private static void ExpandEnvironmentReferences(
        JsonNode node,
        Func<string, string?> environment,
        string path)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var property in obj.ToList())
                {
                    if (property.Value is null)
                    {
                        continue;
                    }

                    if (property.Value is JsonValue value && value.TryGetValue<string>(out var text))
                    {
                        obj[property.Key] = Expand(text, property.Key, environment, path);
                    }
                    else
                    {
                        ExpandEnvironmentReferences(property.Value, environment, path);
                    }
                }

                break;

            case JsonArray array:
                for (var i = 0; i < array.Count; i++)
                {
                    var item = array[i];
                    if (item is null)
                    {
                        continue;
                    }

                    if (item is JsonValue value && value.TryGetValue<string>(out var text))
                    {
                        array[i] = Expand(text, $"[{i}]", environment, path);
                    }
                    else
                    {
                        ExpandEnvironmentReferences(item, environment, path);
                    }
                }

                break;
        }
    }

    private static string Expand(
        string value,
        string context,
        Func<string, string?> environment,
        string path)
    {
        return EnvReference.Replace(value, match =>
        {
            var variable = match.Groups[1].Value;
            return environment(variable)
                ?? throw new InvalidOperationException(
                    $"Config file '{path}' references environment variable '{variable}' " +
                    $"(in '{context}'), which is not set.");
        });
    }

    private static void ValidateDomain(ProculConfig config, ILogger logger)
    {
        ValidateModels(config, logger);
        ValidateAttachments(config);
        ValidateDurations(config);
    }

    private static void ValidateModels(ProculConfig config, ILogger logger)
    {
        if (config.Models.Count == 0)
        {
            throw new InvalidOperationException("Config must define at least one model under 'models'.");
        }

        var slugs = new HashSet<string>(StringComparer.Ordinal);
        var defaults = new List<string>();

        foreach (var (model, index) in config.Models.Select((m, i) => (m, i)))
        {
            var slug = model.Slug?.Trim();
            if (string.IsNullOrWhiteSpace(slug))
            {
                throw new InvalidOperationException($"models[{index}] is missing 'slug'.");
            }

            if (!slugs.Add(slug))
            {
                throw new InvalidOperationException(
                    $"models[{index}] has duplicate slug '{slug}'; every model slug must be unique.");
            }

            if (string.IsNullOrWhiteSpace(model.BaseUrl)
                || !Uri.TryCreate(model.BaseUrl.Trim(), UriKind.Absolute, out var uri)
                || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            {
                throw new InvalidOperationException(
                    $"Model '{slug}' has an invalid 'baseUrl' ('{model.BaseUrl}'); it must be an " +
                    "absolute http(s) URL.");
            }

            if (model.Provider is { Length: > 0 } provider && !AllowedProviders.Contains(provider.Trim()))
            {
                throw new InvalidOperationException(
                    $"Model '{slug}' has unknown provider '{provider}'. " +
                    "Use \"openrouter\" or \"openai-compatible\".");
            }

            foreach (var capability in model.Capabilities ?? [])
            {
                if (!AllowedCapabilities.Contains(capability.Trim()))
                {
                    throw new InvalidOperationException(
                        $"Model '{slug}' declares unknown capability '{capability}'. " +
                        "Allowed: text, image, audio, video, pdf.");
                }
            }

            if (model.Default)
            {
                defaults.Add(slug);
            }
        }

        if (defaults.Count > 1)
        {
            throw new InvalidOperationException(
                $"Exactly one model may set 'default: true', but {defaults.Count} do: " +
                string.Join(", ", defaults) + ".");
        }

        if (defaults.Count == 0)
        {
            logger.LogWarning(
                "No model is marked 'default: true'; using '{Slug}' (the first configured model).",
                config.Models[0].Slug);
        }

        if (!string.IsNullOrWhiteSpace(config.TitleModel)
            && !slugs.Contains(config.TitleModel.Trim()))
        {
            throw new InvalidOperationException(
                $"'titleModel' references '{config.TitleModel}', which is not a configured model slug.");
        }
    }

    private static void ValidateAttachments(ProculConfig config)
    {
        var storage = config.Attachments.Storage?.Trim().ToLowerInvariant() ?? "postgres";
        if (!AllowedStorage.Contains(storage))
        {
            throw new InvalidOperationException(
                $"attachments.storage must be \"postgres\" or \"s3\", not '{config.Attachments.Storage}'.");
        }

        if (storage == "s3" && config.Attachments.S3 is null)
        {
            throw new InvalidOperationException(
                "attachments.storage is \"s3\" but no 'attachments.s3' section is configured.");
        }
    }

    private static void ValidateDurations(ProculConfig config)
    {
        _ = DurationParser.Parse(
            config.Server.SessionLifetime, TimeSpan.FromDays(30), "server.sessionLifetime");
        _ = DurationParser.Parse(
            config.ModelHealth.Interval, TimeSpan.FromMinutes(30), "modelHealth.interval");
        _ = DurationParser.Parse(
            config.ModelHealth.Timeout, TimeSpan.FromSeconds(10), "modelHealth.timeout");
        _ = DurationParser.Parse(
            config.Mcp.ConnectTimeout, TimeSpan.FromSeconds(15), "mcp.connectTimeout");
        _ = DurationParser.Parse(
            config.Mcp.HealthInterval, TimeSpan.FromSeconds(60), "mcp.healthInterval");
    }
}
