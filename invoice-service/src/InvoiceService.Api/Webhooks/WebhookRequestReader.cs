namespace InvoiceService.Api.Webhooks;

/// <summary>Reads the raw parts of an incoming ERP event request.</summary>
public static class WebhookRequestReader
{
    /// <summary>The raw body, or null if it is larger than <paramref name="maxBytes"/> (read no further than
    /// that).</summary>
    public static async Task<byte[]?> ReadBodyAsync(HttpRequest request, int maxBytes, CancellationToken ct)
    {
        if (request.ContentLength > maxBytes)
            return null;

        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await request.Body.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > maxBytes)
                return null;
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    /// <summary>Null when the header is missing or sent more than once.</summary>
    public static string? SingleHeader(HttpRequest request, string name) =>
        request.Headers.TryGetValue(name, out var values) && values.Count == 1 ? values[0] : null;
}
