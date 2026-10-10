using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;
using Procul.Infrastructure.Serialization;

DotNetEnv.Env.Load();

var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonSerializerContext.Default);
});
builder.Services.AddOpenApi();

var app = builder.Build();
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}