using System.Net.Sockets;

namespace InvoiceService.Infrastructure.Erp;

/// <summary>
/// The HTTP handler of the ERP client. Its connections end with a reset, not a graceful close: when a request is given up
/// on (timeout), the kernel drops what it has not delivered yet. Without this, a POST sent just before the network to the
/// ERP broke stays in the kernel's retransmission queue and can reach the ERP after the network comes back, after the next
/// attempt has already asked the ERP and sent the invoice again: a duplicate in the ERP.
/// </summary>
public static class ErpConnections
{
    public static SocketsHttpHandler CreateHandler() => new() { ConnectCallback = ConnectAsync };

    private static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken ct)
    {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(context.DnsEndPoint, ct);
            return new ResettingStream(socket);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>NetworkStream closes gracefully (shutdown, FIN), which keeps undelivered data queued for retransmission;
    /// this one resets the connection first.</summary>
    private sealed class ResettingStream(Socket socket) : NetworkStream(socket, ownsSocket: true)
    {
        protected override void Dispose(bool disposing)
        {
            if (disposing)
                Socket.Close(0);
            base.Dispose(disposing);
        }
    }
}
