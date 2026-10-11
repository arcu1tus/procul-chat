using System.Security.Cryptography;
using System.Text;

namespace Procul.Api.Security;

/// <summary>
/// Verifies a supplied password against the configured one using a constant-time comparison.
///
/// <para>
/// Both values are hashed with SHA-256 first and then compared with
/// <see cref="CryptographicOperations.FixedTimeEquals"/>. Hashing equalizes the length of the
/// compared buffers, so the comparison time does not leak the password's length or how many
/// leading bytes a guess shares with the real password.
/// </para>
/// </summary>
public sealed class PasswordVerifier
{
    private readonly byte[] _expectedHash;

    public PasswordVerifier(string password)
        => _expectedHash = SHA256.HashData(Encoding.UTF8.GetBytes(password));

    /// <summary>Whether <paramref name="supplied"/> matches the configured password.</summary>
    public bool Verify(string? supplied)
    {
        if (string.IsNullOrEmpty(supplied))
        {
            return false;
        }

        var suppliedHash = SHA256.HashData(Encoding.UTF8.GetBytes(supplied));
        return CryptographicOperations.FixedTimeEquals(_expectedHash, suppliedHash);
    }
}
