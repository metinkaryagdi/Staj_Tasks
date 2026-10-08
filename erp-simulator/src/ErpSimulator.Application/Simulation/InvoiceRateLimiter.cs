namespace ErpSimulator.Application.Simulation;

/// <summary>
/// One token bucket for invoice submissions, shared by every client. The bucket holds PermitsPerSecond tokens, each
/// accepted request takes one, and <see cref="Refill"/> fills it back up at the start of every clock second: so no
/// clock second accepts more than PermitsPerSecond requests (a bucket refilled on its own timer could accept a full
/// bucket at the end of one second and another at the start of the next).
/// </summary>
public sealed class InvoiceRateLimiter(IOptions<RateLimitOptions> options)
{
    private readonly Lock _lock = new();
    private int _tokens = options.Value.PermitsPerSecond;

    public int PermitsPerSecond { get; } = options.Value.PermitsPerSecond;

    /// <summary>Takes one token; false when the bucket is empty.</summary>
    public bool TryAcquire()
    {
        lock (_lock)
        {
            if (_tokens == 0)
                return false;
            _tokens--;
            return true;
        }
    }

    /// <summary>Fills the bucket back up to PermitsPerSecond tokens; unused tokens are not carried over.</summary>
    public void Refill()
    {
        lock (_lock)
            _tokens = PermitsPerSecond;
    }

    /// <summary>The start of the clock second after <paramref name="now"/>.</summary>
    public static DateTimeOffset NextSecond(DateTimeOffset now) =>
        new(now.UtcTicks - now.UtcTicks % TimeSpan.TicksPerSecond + TimeSpan.TicksPerSecond, TimeSpan.Zero);
}
