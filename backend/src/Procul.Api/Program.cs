using System.ClientModel;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using OpenAI;
using Procul.Api.Chat.V1;
using Procul.Api.Cors;
using Procul.Api.Infrastructure;
using Procul.Api.Versioning;

DotNetEnv.Env.Load();

var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.AddProculApiVersioning();
builder.Services.AddProculCors(builder.Configuration, builder.Environment);
builder.Services.AddOpenApi();
builder.Services.AddDbContextPool<ProculDbContext>(opt => opt.UseNpgsql(builder.Configuration.GetConnectionString("ChatContext")));

var openRouterModel = builder.Configuration["OPENROUTER_MODEL_SLUG"]
    ?? throw new InvalidOperationException("The OPENROUTER_MODEL_SLUG environment variable is not set.");
var openRouterApiKey = builder.Configuration["OPENROUTER_API_KEY"]
    ?? throw new InvalidOperationException("The OPENROUTER_API_KEY environment variable is not set.");

builder.Services
    .AddChatClient(_ => new OpenAI.Chat.ChatClient(
        model: openRouterModel,
        credential: new ApiKeyCredential(openRouterApiKey),
        options: new OpenAIClientOptions { Endpoint = new Uri("https://openrouter.ai/api/v1") }
    ).AsIChatClient())
    // Without this, tools in ChatOptions.Tools are never executed: the model can request a
    // tool call, but nothing runs it. UseFunctionInvocation wraps the client so tool calls are
    // handled internally and only the final assistant tokens surface to callers.
    .UseFunctionInvocation();

builder.Services.AddScoped<ChatStreamServiceV1>();

var app = builder.Build();

app.UseCors(CorsExtensions.PolicyName);

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

var chat = app.NewVersionedApi("Conversations");
var v1 = chat.MapGroup("/v{version:apiVersion}/conversations").HasApiVersion(1.0);

v1.MapChatV1();

await app.RunAsync();
