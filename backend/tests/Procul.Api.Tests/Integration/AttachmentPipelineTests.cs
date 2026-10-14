using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application (temp config + in-memory EF) and exercises the attachment surface
/// end to end: auth on every route, upload → metadata, download → bytes + headers, idempotent
/// delete, the size/content-type guards, and sending a message whose attachments reach the model
/// as content parts (captured through a fake client).
/// </summary>
public class AttachmentPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";
    private const int MaxFileSize = 1024;

    private readonly WebApplicationFactory<Program> _factory;

    /// <summary>The messages the model received on the last captured turn.</summary>
    private readonly List<ChatMessage> _captured = [];

    private TempConfig? _config;

    public AttachmentPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    public void Dispose() => _config?.Dispose();

    private const string ConfigJson = """
        {
          "server": { "sessionLifetime": "30d" },
          "attachments": {
            "storage": "postgres",
            "maxFileSizeBytes": 1024,
            "maxAttachmentsPerMessage": 2,
            "allowedContentTypes": ["image/*", "text/*", "application/pdf"]
          },
          "models": [
            {
              "slug": "model/one", "name": "One",
              "baseUrl": "https://openrouter.ai/api/v1", "apiKey": "x",
              "provider": "openrouter", "discoverCapabilities": false,
              "capabilities": ["text", "image"], "default": true, "healthCheck": false
            }
          ],
          "modelHealth": { "enabled": false },
          "mcp": { "enabled": false }
        }
        """;

    private WebApplicationFactory<Program> CreateFactory()
    {
        _config = TempConfig.Write(ConfigJson);
        var client = new FakeChatClient(
            (_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "ok"))),
            (messages, _, ct) => CaptureAsync(messages, ct));

        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path)
            .ConfigureServices(services =>
            {
                ReplaceDbWithInMemory(services);
                ReplaceModels(services, client);
            }));
    }

    /// <summary>Captures the turn's messages, then streams a one-token reply.</summary>
    private async IAsyncEnumerable<ChatResponseUpdate> CaptureAsync(
        IEnumerable<ChatMessage> messages,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        _captured.Clear();
        _captured.AddRange(messages);
        yield return new ChatResponseUpdate(ChatRole.Assistant, "ok");
        await Task.CompletedTask;
    }

    private static void ReplaceModels(IServiceCollection services, IChatClient client)
    {
        // Two models with different capabilities, so the send gate (which runs against the
        // conversation's model) can be exercised independently of the upload gate.
        services.RemoveAll<ChatModelRegistry>();
        services.AddSingleton(_ => ChatModelTestHelpers.Registry(
            (ChatModelTestHelpers.Definition(
                slug: "model/one",
                isDefault: true,
                capabilities: [ModelInputModality.Text, ModelInputModality.Image]), client),
            (ChatModelTestHelpers.Definition(
                slug: "model/two",
                isDefault: false,
                capabilities: [ModelInputModality.Text, ModelInputModality.Pdf]), client)));
    }

    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"attachments-{Guid.NewGuid()}";

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
        var response = await client.PostAsJsonAsync("/v1/auth/session", new CreateSessionRequestV1(Password));
        response.EnsureSuccessStatusCode();
        var session = await response.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session!.Token);
        return client;
    }

    private static MultipartFormDataContent FileForm(byte[] bytes, string fileName, string contentType)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        var form = new MultipartFormDataContent { { content, "file", fileName } };
        return form;
    }

    private static async Task<AttachmentV1> UploadAsync(
        HttpClient client,
        byte[] bytes,
        string fileName,
        string contentType,
        string? model = null)
    {
        using var form = FileForm(bytes, fileName, contentType);
        var url = model is null
            ? "/v1/attachments"
            : $"/v1/attachments?model={Uri.EscapeDataString(model)}";
        using var response = await client.PostAsync(url, form);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<AttachmentV1>())!;
    }

    [Fact]
    public async Task Policy_and_media_only_messages_use_the_configured_limit()
    {
        using var factory = CreateFactory();
        using var client = await SignedInClientAsync(factory);
        var policy = await client.GetFromJsonAsync<AttachmentPolicyV1>("/v1/attachments/policy");
        Assert.Equal(2, policy!.MaxAttachmentsPerMessage);
        Assert.Equal(MaxFileSize, policy.MaxFileSizeBytes);
        var attachments = new List<AttachmentV1>();
        for (var i = 0; i < 3; i++) attachments.Add(await UploadAsync(client, [1], $"{i}.png", "image/png"));
        using var tooMany = await client.PostAsJsonAsync("/v1/conversations", new CreateConversationRequestV1("", AttachmentIds: attachments.Select(a => a.Id).ToList()));
        Assert.Equal(HttpStatusCode.BadRequest, tooMany.StatusCode);
        using var valid = await client.PostAsJsonAsync("/v1/conversations", new CreateConversationRequestV1("", AttachmentIds: [attachments[0].Id, attachments[0].Id]));
        valid.EnsureSuccessStatusCode();
        Assert.Contains("done", await valid.Content.ReadAsStringAsync());
        Assert.Single(_captured.Last(m => m.Role == ChatRole.User).Contents.OfType<DataContent>());
    }

    [Fact]
    public async Task Retained_attachments_are_counted_before_a_media_only_edit_truncates_history()
    {
        using var factory = CreateFactory();
        using var client = await SignedInClientAsync(factory);
        var files = new List<AttachmentV1>();
        for (var i = 0; i < 3; i++) files.Add(await UploadAsync(client, [1], $"{i}.png", "image/png"));
        var conversation = new Conversation { Model = "model/one" };
        var user = new ConversationMessage { ConversationId = conversation.Id, Text = "original", MessageRole = MessageRole.User };
        var assistant = new ConversationMessage
        {
            ConversationId = conversation.Id,
            Text = "answer",
            MessageRole = MessageRole.Assistant,
            Reasoning = "saved thinking",
            Model = "model/one",
            ToolCalls = [new() { CallId = "c", Name = "tool", Status = "completed" }]
        };
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
            db.Conversations.Add(conversation);
            db.ConversationMessages.AddRange(user, assistant);
            foreach (var file in files)
            {
                var attachment = await db.Attachments.FindAsync(file.Id);
                attachment!.ConversationId = conversation.Id;
                attachment.MessageId = user.Id;
            }
            await db.SaveChangesAsync();
        }
        var history = await client.GetFromJsonAsync<GetConversationMessagesResponseV1>($"/v1/conversations/{conversation.Id}/messages?limit=1");
        var saved = Assert.Single(history!.Messages);
        Assert.Equal("saved thinking", saved.Reasoning);
        Assert.Equal("model/one", saved.Model);
        Assert.Equal("completed", Assert.Single(saved.ToolCalls!).Status);
        Assert.Null(saved.ToolCalls![0].Result);
        var editUrl = $"/v1/conversations/{conversation.Id}/messages/{user.Id}/edit";
        using var rejected = await client.PostAsJsonAsync(editUrl, new EditMessageRequestV1(""));
        Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
            Assert.Equal("original", (await db.ConversationMessages.FindAsync(user.Id))!.Text);
            Assert.True(await db.ConversationMessages.AnyAsync(m => m.Id == assistant.Id));
        }
        using var accepted = await client.PostAsJsonAsync(editUrl, new EditMessageRequestV1("", AttachmentIds: [files[0].Id]));
        accepted.EnsureSuccessStatusCode();
        Assert.Contains("done", await accepted.Content.ReadAsStringAsync());
        using var finalScope = factory.Services.CreateScope();
        var finalDb = finalScope.ServiceProvider.GetRequiredService<ProculDbContext>();
        Assert.False(await finalDb.ConversationMessages.AnyAsync(m => m.Id == assistant.Id));
        Assert.Empty(await finalDb.Set<ConversationToolCall>().ToListAsync());
    }

    [Fact]
    public async Task Every_attachment_route_requires_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var upload = await client.PostAsync("/v1/attachments", FileForm([1], "a.png", "image/png"));
        using var download = await client.GetAsync($"/v1/attachments/{Guid.NewGuid()}");
        using var delete = await client.DeleteAsync($"/v1/attachments/{Guid.NewGuid()}");
        using var policy = await client.GetAsync("/v1/attachments/policy");

        Assert.Equal(HttpStatusCode.Unauthorized, upload.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, download.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, delete.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, policy.StatusCode);
    }

    [Fact]
    public async Task Upload_download_and_delete_round_trip()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var bytes = new byte[] { 137, 80, 78, 71, 1, 2, 3, 4 };

        var upload = await UploadAsync(client, bytes, "photo.png", "image/png");
        Assert.Equal("photo.png", upload.FileName);
        Assert.Equal("image/png", upload.ContentType);
        Assert.Equal(bytes.Length, upload.SizeBytes);

        using var download = await client.GetAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.OK, download.StatusCode);
        Assert.Equal("image/png", download.Content.Headers.ContentType?.MediaType);
        Assert.Contains("photo.png", download.Content.Headers.ContentDisposition?.ToString());
        Assert.Equal(bytes, await download.Content.ReadAsByteArrayAsync());

        using var deleted = await client.DeleteAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);

        using var gone = await client.GetAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);

        // Deleting again is idempotent, and an unknown id is still 204.
        using var again = await client.DeleteAsync($"/v1/attachments/{upload.Id}");
        using var unknown = await client.DeleteAsync($"/v1/attachments/{Guid.NewGuid()}");
        Assert.Equal(HttpStatusCode.NoContent, again.StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, unknown.StatusCode);
    }

    [Fact]
    public async Task An_oversized_upload_is_rejected_with_413()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var form = FileForm(new byte[MaxFileSize + 1], "big.png", "image/png");
        using var response = await client.PostAsync("/v1/attachments", form);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task A_disallowed_content_type_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var form = FileForm([1, 2, 3], "archive.zip", "application/zip");
        using var response = await client.PostAsync("/v1/attachments", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Sending_an_image_reaches_the_model_as_a_content_part()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var upload = await UploadAsync(client, [1, 2, 3], "cat.png", "image/png");

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("look", AttachmentIds: [upload.Id]));
        await response.Content.ReadAsStringAsync(); // drains the SSE, running the turn

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var user = _captured.Last(m => m.Role == ChatRole.User);
        Assert.Equal("look", user.Contents.OfType<TextContent>().First().Text);
        var image = Assert.IsType<DataContent>(user.Contents.OfType<DataContent>().Single());
        Assert.Equal("image/png", image.MediaType);
    }

    [Fact]
    public async Task Uploading_a_type_the_model_cannot_read_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        // The default model (model/one) accepts text + images, but not PDFs.
        using var form = FileForm([1, 2, 3], "report.pdf", "application/pdf");
        using var response = await client.PostAsync("/v1/attachments?model=model/one", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("report.pdf", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Sending_a_type_the_current_model_cannot_read_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        // model/two accepts PDFs, so the upload succeeds...
        var upload = await UploadAsync(
            client, [1, 2, 3], "report.pdf", "application/pdf", model: "model/two");

        // ...but the conversation runs on model/one, which cannot read a PDF.
        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("read this", Model: "model/one", AttachmentIds: [upload.Id]));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("report.pdf", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task An_unknown_attachment_id_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("hi", AttachmentIds: [Guid.NewGuid()]));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}
