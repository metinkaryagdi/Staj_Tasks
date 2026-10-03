using System.Security.Cryptography;
using System.Text;

namespace ErpSimulator.Application.Webhooks;

/// <summary>
/// X-Erp-Signature = lowercase hex of HMAC-SHA256(secret, "{X-Erp-Timestamp}.{raw body}"), timestamp in Unix seconds.
/// Same format the invoice service checks.
/// </summary>
public static class WebhookSignature
{
    public const string TimestampHeader = "X-Erp-Timestamp";
    public const string SignatureHeader = "X-Erp-Signature";

    public static string Compute(string secret, string timestamp, ReadOnlySpan<byte> body)
    {
        var prefix = Encoding.UTF8.GetBytes(timestamp + ".");
        var signed = new byte[prefix.Length + body.Length];
        prefix.CopyTo(signed, 0);
        body.CopyTo(signed.AsSpan(prefix.Length));
        return Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), signed));
    }
}
