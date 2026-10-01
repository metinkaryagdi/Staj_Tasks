using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace InvoiceService.Webhooks;

/// <summary>Why a signed request was accepted or not. Only written to the log; the 401 response does not say.</summary>
public enum SignatureCheck
{
    Valid,
    MissingHeaders,
    BadTimestamp,
    Expired,
    FromFuture,
    BadSignature
}

/// <summary>
/// X-Erp-Signature = lowercase hex of HMAC-SHA256(secret, "{X-Erp-Timestamp}.{raw body}"), timestamp in Unix seconds.
/// The timestamp is part of what is signed, so an old request cannot be replayed with a fresh timestamp.
/// </summary>
public static class WebhookSignature
{
    public const string TimestampHeader = "X-Erp-Timestamp";
    public const string SignatureHeader = "X-Erp-Signature";

    private const int SignatureBytes = 32; // SHA-256

    public static string Compute(string secret, string timestamp, ReadOnlySpan<byte> body) =>
        Convert.ToHexStringLower(Mac(secret, timestamp, body));

    public static SignatureCheck Verify(
        string secret, string? timestamp, string? signature, ReadOnlySpan<byte> body, DateTimeOffset now, int toleranceSeconds)
    {
        if (string.IsNullOrEmpty(timestamp) || string.IsNullOrEmpty(signature))
            return SignatureCheck.MissingHeaders;

        // Digits only: no sign, no spaces, no decimals.
        if (!long.TryParse(timestamp, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds))
            return SignatureCheck.BadTimestamp;

        // Exactly toleranceSeconds old (or ahead) is still accepted.
        var age = now.ToUnixTimeSeconds() - seconds;
        if (age > toleranceSeconds)
            return SignatureCheck.Expired;
        if (age < -toleranceSeconds)
            return SignatureCheck.FromFuture;

        if (signature.Length != SignatureBytes * 2)
            return SignatureCheck.BadSignature;
        byte[] given;
        try { given = Convert.FromHexString(signature); }
        catch (FormatException) { return SignatureCheck.BadSignature; }

        // Constant time: the comparison takes as long whether the first byte or the last byte differs, so the response
        // time does not tell an attacker how much of a guessed signature is right.
        return CryptographicOperations.FixedTimeEquals(given, Mac(secret, timestamp, body))
            ? SignatureCheck.Valid
            : SignatureCheck.BadSignature;
    }

    private static byte[] Mac(string secret, string timestamp, ReadOnlySpan<byte> body)
    {
        var prefix = Encoding.UTF8.GetBytes(timestamp + ".");
        var signed = new byte[prefix.Length + body.Length];
        prefix.CopyTo(signed, 0);
        body.CopyTo(signed.AsSpan(prefix.Length));
        return HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), signed);
    }
}
