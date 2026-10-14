using InvoiceService.Application.Invoices;

namespace InvoiceService.Application.Metrics;

/// <summary>One reading of the values the metrics take from the database.</summary>
/// <param name="Summary">The same numbers as GET /api/v1/invoices/summary, read the same way.</param>
/// <param name="LastCompletedRunAt">When the newest Tamamlandı reconciliation run finished; null if none has.</param>
public sealed record DatabaseReading(InvoiceSummary Summary, DateTimeOffset? LastCompletedRunAt);

/// <summary>
/// The last database reading, kept between readings so that an export never queries the database. Null before the first
/// reading and after a reading that failed: an export then sends no value rather than an old one.
/// </summary>
public sealed class DatabaseMetrics
{
    private volatile DatabaseReading? _last;

    public DatabaseReading? Last => _last;

    public void Set(DatabaseReading? reading) => _last = reading;
}
