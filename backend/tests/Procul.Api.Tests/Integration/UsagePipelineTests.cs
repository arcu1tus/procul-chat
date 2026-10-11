using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Procul.Api.Chat;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;
using Procul.Api.Usage.V1;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application with an in-memory EF provider substituted for Npgsql (the
/// connection string is left unset, so migrations are skipped) and seeds usage rows directly.
/// Verifies authentication, the lifetime / per-day / per-model shape, and the per-conversation
/// totals used by the in-chat counter.
/// </summary>
public class UsagePipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private static readonly Guid ConversationA = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid ConversationB = Guid.Parse("22222222-2222-2222-2222-222222222222");

    private readonly WebApplicationFactory<Program> _factory;
    private TempConfig? _config;

    public UsagePipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    private WebApplicationFactory<Program> CreateFactory()
    {
        _config = TestConfig.Write();
        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path)
            .ConfigureServices(ReplaceDbWithInMemory));
    }

    public void Dispose() => _config?.Dispose();

    /// <summary>
    /// Swaps the Npgsql-backed context for an isolated in-memory one. The Npgsql
    /// <c>IDbContextOptionsConfiguration</c> must be removed, or EF sees two providers.
    /// </summary>
    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"usage-{Guid.NewGuid()}";

        var toRemove = services
            .Where(descriptor =>
                descriptor.ServiceType == typeof(DbContextOptions<ProculDbContext>) ||
                descriptor.ServiceType == typeof(DbContextOptions) ||
                descriptor.ServiceType == typeof(ProculDbContext) ||
                IsGenericOf(descriptor.ServiceType, "Microsoft.EntityFrameworkCore.Infrastructure.IDbContextOptionsConfiguration`1"))
            .ToList();

        foreach (var descriptor in toRemove)
        {
            services.Remove(descriptor);
        }

        services.AddDbContext<ProculDbContext>(options => options.UseInMemoryDatabase(database));
    }

    private static bool IsGenericOf(Type type, string genericDefinitionFullName) =>
        type.IsGenericType &&
        type.GetGenericTypeDefinition().FullName == genericDefinitionFullName;

    private static async Task<HttpClient> SignedInClientAsync(WebApplicationFactory<Program> factory)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync(
            "/v1/auth/session", new CreateSessionRequestV1(Password));
        response.EnsureSuccessStatusCode();
        var session = await response.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", session!.Token);
        return client;
    }

    private static DateTimeOffset At(DateOnly day) =>
        new(day.ToDateTime(new TimeOnly(12, 0)), TimeSpan.Zero);

    private static TurnUsage Row(DateOnly day, Guid conversation, string model, TurnKind kind, long input, long output)
    {
        var cached = Math.Min(input, 20);
        return new TurnUsage
        {
            ConversationId = conversation,
            Model = model,
            Kind = kind,
            InputTokens = input,
            OutputTokens = output,
            CachedInputTokens = cached,
            TotalTokens = input + output,
            CreatedAt = At(day),
        };
    }

    private static async Task SeedAsync(WebApplicationFactory<Program> factory)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
        db.TurnUsages.AddRange(
            Row(today, ConversationA, "test/model", TurnKind.Chat, 100, 50),
            Row(today.AddDays(-1), ConversationA, "test/model", TurnKind.Title, 10, 5),
            Row(today.AddDays(-3), ConversationB, "other/model", TurnKind.Chat, 7, 3),
            Row(today.AddDays(-60), ConversationA, "test/model", TurnKind.Chat, 1, 1));
        await db.SaveChangesAsync();
    }

    [Fact]
    public async Task The_usage_endpoints_require_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var summary = await client.GetAsync("/v1/usage");
        using var conversation = await client.GetAsync($"/v1/usage/conversations/{ConversationA}");

        Assert.Equal(HttpStatusCode.Unauthorized, summary.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, conversation.StatusCode);
    }

    [Fact]
    public async Task Rejects_an_out_of_range_window()
    {
        var factory = CreateFactory();
        await SeedAsync(factory);
        using var client = await SignedInClientAsync(factory);

        using var tooSmall = await client.GetAsync("/v1/usage?days=0");
        using var tooLarge = await client.GetAsync("/v1/usage?days=367");

        Assert.Equal(HttpStatusCode.BadRequest, tooSmall.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, tooLarge.StatusCode);
    }

    [Fact]
    public async Task Returns_lifetime_totals_days_and_models()
    {
        var factory = CreateFactory();
        await SeedAsync(factory);
        using var client = await SignedInClientAsync(factory);

        var body = await client.GetFromJsonAsync<GetUsageResponseV1>("/v1/usage?days=30");

        Assert.NotNull(body);

        // Lifetime spans every row, including the one older than the window.
        Assert.Equal(118, body!.Lifetime.InputTokens);
        Assert.Equal(59, body.Lifetime.OutputTokens);
        Assert.Equal(38, body.Lifetime.CachedInputTokens);
        Assert.Equal(177, body.Lifetime.TotalTokens);
        Assert.Equal(4, body.Lifetime.Turns);

        // The window is zero-filled to exactly the requested number of days.
        Assert.Equal(30, body.Days.Count);

        var today = DateOnly.FromDateTime(DateTime.UtcNow).ToString("yyyy-MM-dd");
        var yesterday = DateOnly.FromDateTime(DateTime.UtcNow).AddDays(-1).ToString("yyyy-MM-dd");
        Assert.Equal(150, body.Days.Single(d => d.Date == today).TotalTokens);
        Assert.Equal(1, body.Days.Single(d => d.Date == today).Turns);
        Assert.Equal(15, body.Days.Single(d => d.Date == yesterday).TotalTokens);

        // The 60-day-old row is outside the window: it contributes to lifetime but not to days.
        Assert.Equal(175, body.Days.Sum(d => d.TotalTokens));

        // Models are windowed and ranked by total.
        var test = body.Models.Single(m => m.Model == "test/model");
        Assert.Equal(165, test.TotalTokens);
        Assert.Equal(2, test.Turns);
        Assert.Equal(10, body.Models.Single(m => m.Model == "other/model").TotalTokens);
        Assert.Equal(2, body.Models.Count);
    }

    [Fact]
    public async Task Returns_totals_for_one_conversation()
    {
        var factory = CreateFactory();
        await SeedAsync(factory);
        using var client = await SignedInClientAsync(factory);

        var a = await client.GetFromJsonAsync<UsageTotalsV1>($"/v1/usage/conversations/{ConversationA}");
        var b = await client.GetFromJsonAsync<UsageTotalsV1>($"/v1/usage/conversations/{ConversationB}");

        Assert.NotNull(a);
        Assert.Equal(111, a!.InputTokens);
        Assert.Equal(56, a.OutputTokens);
        Assert.Equal(167, a.TotalTokens);
        Assert.Equal(3, a.Turns);

        Assert.NotNull(b);
        Assert.Equal(10, b!.TotalTokens);
        Assert.Equal(1, b.Turns);
    }

    [Fact]
    public async Task An_unknown_conversation_has_zero_totals()
    {
        var factory = CreateFactory();
        await SeedAsync(factory);
        using var client = await SignedInClientAsync(factory);

        var totals = await client.GetFromJsonAsync<UsageTotalsV1>($"/v1/usage/conversations/{Guid.NewGuid()}");

        Assert.NotNull(totals);
        Assert.Equal(0, totals!.TotalTokens);
        Assert.Equal(0, totals.Turns);
    }
}
