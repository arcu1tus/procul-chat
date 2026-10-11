using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;

namespace Procul.Api.Mcp;

/// <summary>A point-in-time, secret-free view of one configured MCP server.</summary>
public sealed record McpServerStatus(
    string Name,
    string Type,
    string Url,
    bool Connected,
    int ToolCount,
    IReadOnlyList<string> Tools,
    string? LastError,
    DateTimeOffset? LastConnectedAt
);

/// <summary>
/// Owns every MCP client connection: connects and discovers tools at startup, publishes the
/// namespaced tool set to the chat turn, keeps the connections healthy in the background, and
/// reports status. A dead server is marked unavailable and retried — it never blocks or crashes
/// startup. Headers (and therefore tokens) are never logged or exposed.
/// </summary>
internal sealed class McpClientManager : IHostedService, IAsyncDisposable
{
    private readonly McpOptions _options;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<McpClientManager> _logger;

    /// <summary>Guards the mutable per-server state and the published snapshots.</summary>
    private readonly object _stateLock = new();

    private readonly List<ServerEntry> _servers = [];
    private readonly CancellationTokenSource _stopping = new();
    private Task? _healthLoop;

    private volatile IReadOnlyList<AITool> _tools = [];
    private volatile string _systemPromptSuffix = string.Empty;

    public McpClientManager(
        McpOptions options,
        ILoggerFactory loggerFactory,
        ILogger<McpClientManager> logger)
    {
        _options = options;
        _loggerFactory = loggerFactory;
        _logger = logger;
    }

    /// <summary>Snapshot of the tools currently published to the model (atomic swap).</summary>
    public IReadOnlyList<AITool> Tools => _tools;

    /// <summary>
    /// Server-provided instructions to append to the base system prompt, or empty when no server
    /// advertises any.
    /// </summary>
    public string SystemPromptSuffix => _systemPromptSuffix;

    /// <summary>Connects to every enabled server (in parallel, bounded) and starts the health loop.</summary>
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogInformation("MCP: disabled via {Setting}.", McpOptions.EnabledSetting);
            return;
        }

        // A bad config file is fatal (fail fast); a dead server is not.
        var definitions = McpConfigLoader.Load(_options, _logger);

        var entries = definitions.Select(definition => new ServerEntry(definition)).ToList();
        lock (_stateLock)
        {
            _servers.Clear();
            _servers.AddRange(entries);
        }

        if (entries.Count > 0)
        {
            await Task.WhenAll(entries.Select(entry => ConnectAsync(entry, cancellationToken)));
            RebuildSnapshot();
        }

        _healthLoop = Task.Run(() => HealthLoopAsync(_stopping.Token), CancellationToken.None);
    }

    /// <summary>Stops the health loop and disposes every client.</summary>
    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _stopping.CancelAsync();

        if (_healthLoop is not null)
        {
            try
            {
                await _healthLoop;
            }
            catch (OperationCanceledException)
            {
                // Expected when the loop is cancelled.
            }
        }

        foreach (var entry in SnapshotEntries())
        {
            await DisposeClientAsync(entry);
        }
    }

    /// <summary>Reconnects to one server by name. Returns false when no such server is configured.</summary>
    public async Task<bool> ReconnectAsync(string name, CancellationToken cancellationToken)
    {
        var entry = SnapshotEntries().FirstOrDefault(
            e => string.Equals(e.Definition.Name, name, StringComparison.OrdinalIgnoreCase));
        if (entry is null)
        {
            return false;
        }

        await ConnectAsync(entry, cancellationToken);
        RebuildSnapshot();
        lock (_stateLock)
        {
            return entry.Connected;
        }
    }

    /// <summary>Returns a secret-free status snapshot for every configured server.</summary>
    public IReadOnlyList<McpServerStatus> GetStatuses()
    {
        lock (_stateLock)
        {
            return _servers
                .Select(entry => new McpServerStatus(
                    entry.Definition.Name,
                    entry.Definition.TypeName,
                    entry.Definition.Url,
                    entry.Connected,
                    entry.ToolCount,
                    entry.ToolNames,
                    entry.LastError,
                    entry.LastConnectedAt))
                .ToList();
        }
    }

    /// <summary>Connects (or reconnects) a single server, bounded by the connect timeout.</summary>
    private async Task ConnectAsync(ServerEntry entry, CancellationToken cancellationToken)
    {
        await entry.Gate.WaitAsync(cancellationToken);
        try
        {
            await DisposeClientAsync(entry);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_options.ConnectTimeout);

            HttpClientTransport? transport = null;
            McpClient? client = null;
            try
            {
                transport = new HttpClientTransport(
                    new HttpClientTransportOptions
                    {
                        Name = entry.Definition.Name,
                        Endpoint = new Uri(entry.Definition.Url),
                        TransportMode = entry.Definition.Type == McpTransportType.Sse
                            ? HttpTransportMode.Sse
                            : HttpTransportMode.StreamableHttp,
                        AdditionalHeaders = new Dictionary<string, string>(entry.Definition.Headers),
                    },
                    _loggerFactory);

                client = await McpClient.CreateAsync(
                    transport,
                    new McpClientOptions { InitializationTimeout = _options.ConnectTimeout },
                    _loggerFactory,
                    timeout.Token);

                // The client now owns the transport.
                transport = null;

                var tools = await client.ListToolsAsync(cancellationToken: timeout.Token);

                lock (_stateLock)
                {
                    entry.Client = client;
                    entry.Tools = [.. tools];
                    entry.Connected = true;
                    entry.ToolCount = tools.Count;
                    entry.ToolNames = [.. tools.Select(tool => tool.Name)];
                    entry.ServerInstructions = client.ServerInstructions;
                    entry.LastError = null;
                    entry.LastConnectedAt = DateTimeOffset.UtcNow;
                    entry.ConsecutiveFailures = 0;
                    entry.NextAttemptAt = null;
                }

                _logger.LogInformation(
                    "mcp[{Name}]: connected — {Count} tools", entry.Definition.Name, tools.Count);
            }
            catch (Exception ex)
            {
                if (client is not null)
                {
                    await SafeDisposeAsync(client);
                }
                else if (transport is not null)
                {
                    await SafeDisposeAsync(transport);
                }

                var message = Describe(ex);
                lock (_stateLock)
                {
                    entry.Connected = false;
                    entry.ToolCount = 0;
                    entry.ToolNames = [];
                    entry.ServerInstructions = null;
                    entry.LastError = message;
                    entry.ConsecutiveFailures++;
                    entry.NextAttemptAt = DateTimeOffset.UtcNow + Backoff(entry.ConsecutiveFailures);
                }

                _logger.LogWarning("mcp[{Name}]: failed — {Error}", entry.Definition.Name, message);
            }
        }
        finally
        {
            entry.Gate.Release();
        }
    }

    private async Task HealthLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(_options.HealthInterval, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            foreach (var entry in SnapshotEntries())
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                await CheckAsync(entry, cancellationToken);
            }

            RebuildSnapshot();
        }
    }

    /// <summary>Pings a connected server, reconnecting it when the ping fails or it is down.</summary>
    private async Task CheckAsync(ServerEntry entry, CancellationToken cancellationToken)
    {
        bool connected;
        McpClient? client;
        DateTimeOffset? nextAttemptAt;
        lock (_stateLock)
        {
            connected = entry.Connected;
            client = entry.Client;
            nextAttemptAt = entry.NextAttemptAt;
        }

        // A server that just failed waits out its backoff before another attempt.
        if (nextAttemptAt is { } at && DateTimeOffset.UtcNow < at)
        {
            return;
        }

        if (connected && client is not null)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(_options.ConnectTimeout);
                await client.PingAsync(cancellationToken: timeout.Token);
                return;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    "mcp[{Name}]: ping failed — {Error}; reconnecting",
                    entry.Definition.Name, Describe(ex));

                lock (_stateLock)
                {
                    entry.Connected = false;
                    entry.LastError = Describe(ex);
                }

                await DisposeClientAsync(entry);
            }
        }

        await ConnectAsync(entry, cancellationToken);
    }

    /// <summary>
    /// Rebuilds the published tool list and system-prompt suffix from the connected servers.
    /// Names are deduplicated across every server and the built-ins.
    /// </summary>
    private void RebuildSnapshot()
    {
        var assigner = new McpToolNameAssigner();
        var tools = new List<AITool>();
        var instructions = new List<string>();

        lock (_stateLock)
        {
            foreach (var entry in _servers)
            {
                if (!entry.Connected)
                {
                    continue;
                }

                foreach (var tool in entry.Tools)
                {
                    var name = assigner.Assign(entry.Definition.Name, tool.Name);
                    tools.Add(tool.WithName(name));
                }

                if (!string.IsNullOrWhiteSpace(entry.ServerInstructions))
                {
                    instructions.Add(entry.ServerInstructions.Trim());
                }
            }
        }

        _tools = tools;
        _systemPromptSuffix = instructions.Count == 0
            ? string.Empty
            : "\n\n" + string.Join("\n\n", instructions);
    }

    private List<ServerEntry> SnapshotEntries()
    {
        lock (_stateLock)
        {
            return [.. _servers];
        }
    }

    private async Task DisposeClientAsync(ServerEntry entry)
    {
        McpClient? client;
        lock (_stateLock)
        {
            client = entry.Client;
            entry.Client = null;
        }

        if (client is not null)
        {
            await SafeDisposeAsync(client);
        }
    }

    private async Task SafeDisposeAsync(IAsyncDisposable disposable)
    {
        try
        {
            await disposable.DisposeAsync();
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "MCP: disposing a connection failed.");
        }
    }

    private TimeSpan Backoff(int failures)
    {
        var seconds = _options.HealthInterval.TotalSeconds * Math.Pow(2, Math.Min(failures, 4));
        return TimeSpan.FromSeconds(Math.Min(seconds, TimeSpan.FromMinutes(10).TotalSeconds));
    }

    /// <summary>A concise, token-free description of a connection failure.</summary>
    private static string Describe(Exception ex) => ex switch
    {
        HttpRequestException { StatusCode: { } status } => $"{(int)status} {status}",
        OperationCanceledException => "timed out",
        _ => ex.Message,
    };

    public async ValueTask DisposeAsync()
    {
        await _stopping.CancelAsync();

        foreach (var entry in SnapshotEntries())
        {
            await DisposeClientAsync(entry);
        }
    }

    /// <summary>Mutable state for one configured server.</summary>
    private sealed class ServerEntry(McpServerDefinition definition)
    {
        /// <summary>Serializes connect/disconnect for this server only, so startup stays parallel.</summary>
        public SemaphoreSlim Gate { get; } = new(1, 1);

        public McpServerDefinition Definition { get; } = definition;

        public McpClient? Client { get; set; }
        public bool Connected { get; set; }
        public int ToolCount { get; set; }
        public IReadOnlyList<string> ToolNames { get; set; } = [];
        public List<McpClientTool> Tools { get; set; } = [];
        public string? ServerInstructions { get; set; }
        public string? LastError { get; set; }
        public DateTimeOffset? LastConnectedAt { get; set; }
        public int ConsecutiveFailures { get; set; }
        public DateTimeOffset? NextAttemptAt { get; set; }
    }
}
