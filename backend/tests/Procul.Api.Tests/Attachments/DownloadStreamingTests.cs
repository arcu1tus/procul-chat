using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Procul.Api.Attachments;

namespace Procul.Api.Tests.Attachments;

public class DownloadStreamingTests
{
    [Fact]
    public async Task A_forward_only_download_delivers_before_completion_and_closes_on_disconnect()
    {
        var source = new DelayedStream();
        var owner = new ResponseOwner();
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.UseKestrel().UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        app.MapGet("/file", () => TypedResults.File(new OwnedDownloadStream(source, owner), "application/octet-stream"));
        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
        using var client = new HttpClient();
        using var response = await client.GetAsync(address + "/file", HttpCompletionOption.ResponseHeadersRead);
        await using var download = await response.Content.ReadAsStreamAsync();
        var buffer = new byte[1024];
        Assert.True(await download.ReadAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(3)) > 0);
        Assert.True(source.ReadSize <= 81_920);
        Assert.False(source.Disposed.Task.IsCompleted);
        response.Dispose();
        client.Dispose();
        await source.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await owner.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await app.StopAsync();
    }

    private sealed class ResponseOwner : IDisposable
    {
        public TaskCompletionSource Disposed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Dispose() => Disposed.TrySetResult();
    }
    private sealed class DelayedStream : Stream
    {
        private bool _sent;
        public int ReadSize;
        public TaskCompletionSource Disposed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            ReadSize = Math.Max(ReadSize, buffer.Length);
            if (!_sent) { _sent = true; buffer.Span.Fill(42); return buffer.Length; }
            await Task.Delay(Timeout.Infinite, ct);
            return 0;
        }
        protected override void Dispose(bool disposing) { if (disposing) Disposed.TrySetResult(); base.Dispose(disposing); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
