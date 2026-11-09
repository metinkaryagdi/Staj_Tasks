using System.Net;
using System.Net.Sockets;
using InvoiceService.Infrastructure.Erp;

namespace InvoiceService.Infrastructure.Tests;

public class ErpConnectionsTests
{
    /// <summary>
    /// A request given up on (timeout) resets the connection instead of closing it gracefully: the ERP side sees a reset,
    /// so nothing the client had not delivered can still arrive later.
    /// </summary>
    [Fact]
    public async Task A_request_given_up_on_resets_the_connection()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;

        using var http = new HttpClient(ErpConnections.CreateHandler()) { Timeout = TimeSpan.FromMilliseconds(500) };
        var request = http.PostAsync($"http://127.0.0.1:{port}/api/v1/invoices", new StringContent("{}"));

        using var server = await listener.AcceptSocketAsync();
        var buffer = new byte[4096];
        Assert.True(await server.ReceiveAsync(buffer, SocketFlags.None) > 0);
        await Assert.ThrowsAsync<TaskCanceledException>(() => request);

        // The ERP never answered; after the client gives up, the next read sees how the connection ended.
        var ended = await Assert.ThrowsAsync<SocketException>(async () =>
        {
            while (await server.ReceiveAsync(buffer, SocketFlags.None) > 0) { }
        });
        Assert.Equal(SocketError.ConnectionReset, ended.SocketErrorCode);
    }
}
