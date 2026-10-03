using InvoiceService.Application.Abstractions;
using Npgsql;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class PostgresFailureClassifier : IDatabaseFailureClassifier
{
    public string? TimeoutReason(Exception ex)
    {
        for (var e = ex; e is not null; e = e.InnerException)
        {
            if (e is PostgresException pg)
                return pg.SqlState switch
                {
                    PostgresErrorCodes.LockNotAvailable => "lock-timeout",
                    PostgresErrorCodes.QueryCanceled => "statement-timeout",
                    _ => null
                };
        }
        return null;
    }
}
