using System.Security.Cryptography;
using System.Text;

namespace InvoiceService.Application.Abstractions;

/// <summary>The share of invoices that use the ERP's new API. One row in the database: every copy of the service reads the
/// same value and a change needs no restart.</summary>
public interface IErpVersionSetting
{
    /// <summary>0: everything uses v1. 100: everything uses v2.</summary>
    Task<int> GetV2PercentAsync(CancellationToken ct);

    Task SetV2PercentAsync(int percent, CancellationToken ct);
}

public static class ErpVersion
{
    public const int V1 = 1;
    public const int V2 = 2;

    /// <summary>
    /// An invoice number always falls in the same bucket (0-99), on every copy. So raising the share only moves invoices
    /// from v1 to v2, and an invoice's send, cancellation and questions use the same version while the share stays.
    /// </summary>
    public static int For(string invoiceNumber, int v2Percent)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(invoiceNumber));
        var bucket = BitConverter.ToUInt32(hash, 0) % 100;
        return bucket < v2Percent ? V2 : V1;
    }

    /// <summary>The whole-list question belongs to no invoice: it leaves v1 last, and is back on v1 at once after a
    /// rollback.</summary>
    public static int ForList(int v2Percent) => v2Percent >= 100 ? V2 : V1;
}
