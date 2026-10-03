using System.Globalization;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// Bound from the "Outbox" section of appsettings.json. No defaults in code: a missing value stops the app at startup.
/// The shipped values are the task's rules (10 sends at a time, 10 attempts, waits up to 60 s) and our own choices for
/// the jitter, the lock and the idle delay.
/// </summary>
public sealed class OutboxOptions
{
    public const string SectionName = "Outbox";

    /// <summary>How many ERP sends the worker runs at the same time (per service instance).</summary>
    public int MaxConcurrentSends { get; set; }

    /// <summary>How many attempts an invoice gets; after the last one fails it is Başarısız.</summary>
    public int MaxAttempts { get; set; }

    /// <summary>No backoff wait (500, timeout, ERP unreachable) is longer than this, jitter included.</summary>
    public int MaxBackoffSeconds { get; set; }

    /// <summary>The random jitter added to each backoff wait is in [0, this).</summary>
    public int MaxJitterMilliseconds { get; set; }

    /// <summary>
    /// Room left below <see cref="MaxBackoffSeconds"/>: the longest planned wait is MaxBackoffSeconds minus this. 0 means
    /// a planned wait can reach MaxBackoffSeconds (jitter included). The real gap between two attempts is a little longer
    /// than planned (the worker looks for due entries every IdleDelayMilliseconds and taking the entry takes a moment),
    /// so if the measured gap must also stay under MaxBackoffSeconds, set this to about 1000.
    /// </summary>
    public int BackoffMarginMilliseconds { get; set; }

    /// <summary>
    /// How long a taken entry belongs to the worker that took it. If the service is killed mid-send, another worker
    /// takes the entry once this has passed. Must be longer than the longest attempt (see the validator).
    /// </summary>
    public int LockSeconds { get; set; }

    /// <summary>How long the worker waits before looking again when nothing is due.</summary>
    public int IdleDelayMilliseconds { get; set; }
}

public sealed class OutboxOptionsValidator(IConfiguration configuration) : IValidateOptions<OutboxOptions>
{
    public static readonly string[] RequiredKeys =
    [
        nameof(OutboxOptions.MaxConcurrentSends), nameof(OutboxOptions.MaxAttempts), nameof(OutboxOptions.MaxBackoffSeconds),
        nameof(OutboxOptions.MaxJitterMilliseconds), nameof(OutboxOptions.BackoffMarginMilliseconds),
        nameof(OutboxOptions.LockSeconds), nameof(OutboxOptions.IdleDelayMilliseconds)
    ];

    /// <summary>
    /// The longest attempt asks the ERP, sends, and asks again before giving up: three requests, each up to
    /// Erp:TimeoutSeconds. The lock must outlast that, or a second worker could take an entry that is still being sent.
    /// </summary>
    public const int RequestsPerAttempt = 3;

    public ValidateOptionsResult Validate(string? name, OutboxOptions options)
    {
        var errors = new List<string>();

        var section = configuration.GetSection(OutboxOptions.SectionName);
        foreach (var key in RequiredKeys)
        {
            if (string.IsNullOrWhiteSpace(section[key]))
                errors.Add($"{OutboxOptions.SectionName}:{key} is missing from the settings file.");
        }
        if (errors.Count > 0)
            return ValidateOptionsResult.Fail(errors);

        if (options.MaxConcurrentSends <= 0)
            errors.Add($"Outbox:MaxConcurrentSends must be greater than 0 (was {options.MaxConcurrentSends}).");
        if (options.MaxAttempts <= 0)
            errors.Add($"Outbox:MaxAttempts must be greater than 0 (was {options.MaxAttempts}).");
        if (options.MaxBackoffSeconds <= 0)
            errors.Add($"Outbox:MaxBackoffSeconds must be greater than 0 (was {options.MaxBackoffSeconds}).");
        // long: seconds * 1000 and jitter + margin must not overflow int into a negative number for very large values.
        var maxBackoffMs = (long)options.MaxBackoffSeconds * 1000;
        if (options.MaxJitterMilliseconds < 0 || options.MaxJitterMilliseconds >= maxBackoffMs)
            errors.Add($"Outbox:MaxJitterMilliseconds must be at least 0 and less than Outbox:MaxBackoffSeconds " +
                       $"(was {options.MaxJitterMilliseconds} ms, max backoff {options.MaxBackoffSeconds} s).");
        if (options.BackoffMarginMilliseconds < 0
            || (long)options.MaxJitterMilliseconds + options.BackoffMarginMilliseconds >= maxBackoffMs)
            errors.Add($"Outbox:BackoffMarginMilliseconds must be at least 0, and with the jitter less than Outbox:MaxBackoffSeconds " +
                       $"(was {options.BackoffMarginMilliseconds} ms, jitter {options.MaxJitterMilliseconds} ms, max backoff {options.MaxBackoffSeconds} s).");
        if (options.IdleDelayMilliseconds <= 0)
            errors.Add($"Outbox:IdleDelayMilliseconds must be greater than 0 (was {options.IdleDelayMilliseconds}).");

        if (int.TryParse(configuration["Erp:TimeoutSeconds"], NumberStyles.Integer, CultureInfo.InvariantCulture, out var timeout)
            && options.LockSeconds <= (long)RequestsPerAttempt * timeout)
        {
            errors.Add($"Outbox:LockSeconds must be longer than {RequestsPerAttempt} x Erp:TimeoutSeconds " +
                       $"(was {options.LockSeconds} s, timeout {timeout} s): an attempt can take that long.");
        }
        else if (options.LockSeconds <= 0)
        {
            errors.Add($"Outbox:LockSeconds must be greater than 0 (was {options.LockSeconds}).");
        }

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
