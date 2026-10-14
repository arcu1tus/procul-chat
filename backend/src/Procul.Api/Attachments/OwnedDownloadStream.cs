namespace Procul.Api.Attachments;

/// <summary>A forward-only download stream that owns the storage response for its entire lifetime.</summary>
internal sealed class OwnedDownloadStream(Stream source, IDisposable response) : Stream
{
    private bool _disposed;
    public override bool CanRead => source.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => source.Read(buffer, offset, count);
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => source.ReadAsync(buffer, offset, count, ct);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => source.ReadAsync(buffer, ct);
    protected override void Dispose(bool disposing)
    {
        if (disposing && !_disposed)
        {
            _disposed = true;
            try { source.Dispose(); }
            finally { response.Dispose(); }
        }
        base.Dispose(disposing);
    }
    public override async ValueTask DisposeAsync()
    {
        if (!_disposed)
        {
            _disposed = true;
            try { await source.DisposeAsync(); }
            finally { response.Dispose(); }
        }
        GC.SuppressFinalize(this);
    }
    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
