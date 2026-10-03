namespace InvoiceService.Application.Abstractions;

/// <summary>Tells which database failures mean "the database stopped the work on its own time limits".</summary>
public interface IDatabaseFailureClassifier
{
    /// <summary>
    /// "lock-timeout" / "statement-timeout" when the database stopped the transaction on its limits (lock_timeout,
    /// statement_timeout), looking through inner exceptions; null for any other failure.
    /// </summary>
    string? TimeoutReason(Exception ex);
}
