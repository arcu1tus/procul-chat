using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Cors;
using Procul.Api.Infrastructure;
using Procul.Api.Versioning;

DotNetEnv.Env.Load();

var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.AddProculApiVersioning();
builder.Services.AddProculCors(builder.Configuration, builder.Environment);
builder.Services.AddOpenApi();
builder.Services.AddProculDbContext(builder.Configuration);
builder.Services.AddProculChat(builder.Configuration);

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
