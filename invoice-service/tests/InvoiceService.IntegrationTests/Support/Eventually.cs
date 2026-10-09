namespace InvoiceService.IntegrationTests.Support;

public static class Eventually
{
    /// <summary>
    /// Waits until the condition holds instead of for a fixed time: it is checked every 20 ms and the test fails with
    /// <paramref name="what"/> if it does not hold within the limit. The limit only bounds a broken test; a passing one
    /// returns as soon as the condition is true.
    /// </summary>
    public static async Task WaitUntilAsync(Func<Task<bool>> condition, string what, int limitSeconds = 20)
    {
        var deadline = DateTime.UtcNow.AddSeconds(limitSeconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > deadline)
                throw new TimeoutException($"Waited {limitSeconds} s for: {what}");
            await Task.Delay(20);
        }
    }
}
