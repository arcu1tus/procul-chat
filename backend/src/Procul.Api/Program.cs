using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;
using Procul.Api.Cors;
using Procul.Api.Infrastructure;
using Procul.Api.Images;
using Procul.Api.Mcp;
using Procul.Api.Mcp.V1;
using Procul.Api.Security;
using Procul.Api.Security.V1;
using Procul.Api.Usage.V1;
using Procul.Api.Versioning;

DotNetEnv.Env.Load();

var builder = WebApplication.CreateSlimBuilder(args);

// Load config.jsonc once, before any DI wiring. A missing or invalid config is fatal.
using var bootstrapLoggerFactory = LoggerFactory.Create(logging => logging.AddSimpleConsole());
var config = ProculConfigLoader.Load(
    builder.Configuration,
    bootstrapLoggerFactory.CreateLogger("Procul.Config"));

// Allow a multipart upload as large as the configured cap (plus multipart/overhead slack).
builder.WebHost.ConfigureKestrel(kestrel =>
    kestrel.Limits.MaxRequestBodySize = config.Attachments.MaxFileSizeBytes + (1024 * 1024));

builder.Services.AddSingleton(config);
builder.Services.AddSingleton(AttachmentOptions.FromConfig(config));

builder.Services.AddProculApiVersioning();
builder.Services.AddProculCors(config, builder.Environment);
builder.Services.AddOpenApi();
builder.Services.AddProculAuth(builder.Configuration, config);
builder.Services.AddProculDbContext(config);
builder.Services.AddProculChat(config);
builder.Services.AddProculAttachments(config);
builder.Services.AddProculImageGeneration(config);
builder.Services.AddProculMcp(config);

var app = builder.Build();

await app.ApplyProculMigrationsAsync();

app.UseProculCors();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

// Public liveness probe: no password required, so orchestrators can check the process.
app.MapGet("/health", () => TypedResults.Ok(new HealthResponseV1("healthy")));

app.UseProculAuth();

var auth = app.NewVersionedApi("Auth");
var v1Auth = auth.MapGroup("/v{version:apiVersion}/auth").HasApiVersion(1.0);
v1Auth.MapAuthV1();

var chat = app.NewVersionedApi("Conversations");
var v1 = chat
    .MapGroup("/v{version:apiVersion}/conversations")
    .HasApiVersion(1.0)
    .RequireAuthorization();

v1.MapChatV1();

var models = app.NewVersionedApi("Models");
var v1Models = models
    .MapGroup("/v{version:apiVersion}/models")
    .HasApiVersion(1.0)
    .RequireAuthorization();

v1Models.MapModelsV1();

var mcp = app.NewVersionedApi("Mcp");
var v1Mcp = mcp
    .MapGroup("/v{version:apiVersion}/mcp")
    .HasApiVersion(1.0)
    .RequireAuthorization();

v1Mcp.MapMcpV1();

var usage = app.NewVersionedApi("Usage");
var v1Usage = usage
    .MapGroup("/v{version:apiVersion}/usage")
    .HasApiVersion(1.0)
    .RequireAuthorization();

v1Usage.MapUsageV1();

var attachments = app.NewVersionedApi("Attachments");
var v1Attachments = attachments
    .MapGroup("/v{version:apiVersion}/attachments")
    .HasApiVersion(1.0)
    .RequireAuthorization();

v1Attachments.MapAttachmentsV1();

await app.RunAsync();

/// <summary>
/// Exposed so the integration test project can boot the real application via
/// <c>WebApplicationFactory&lt;Program&gt;</c>.
/// </summary>
public partial class Program
{
}

/// <summary>The body of the public <c>GET /health</c> probe.</summary>
internal sealed record HealthResponseV1(string Status);
