using System.Diagnostics;
using System.Net;
using System.Text.Json;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.Configuration;
using Xunit.Abstractions;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// A key removed from Keycloak stays in the service's key list until the service reads the list again, every
/// Keycloak:JwksRefreshMinutes plus up to 5% at random; a key already in the list does not make it read sooner. The test
/// removes the key right after the service has read the list (the worst order) and checks that the removed key is
/// accepted until the refresh time and refused soon after it. It waits a little over the refresh time (about 5.5 min).
/// </summary>
public class KeyRefreshTests(PostgresFixture postgres, KeycloakFixture keycloak, ITestOutputHelper output)
    : AuthTest(postgres, keycloak)
{
    private const string Realm = "yenileme-realm";

    // After the refresh time the next request is still checked with the old list and starts the read in the background;
    // the test asks once a second, so the refusal comes one or two requests later.
    private static readonly TimeSpan ReadAndAsk = TimeSpan.FromSeconds(6);

    protected override Dictionary<string, string?> Settings()
    {
        var settings = base.Settings();
        settings["Keycloak:Realm"] = Realm;
        return settings;
    }

    [Fact]
    public async Task A_removed_key_is_accepted_until_the_key_list_is_read_again_and_refused_after()
    {
        // The value the service ships with, not one shortened for the test.
        var refresh = TimeSpan.FromMinutes(new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(AppContext.BaseDirectory, "appsettings.json")).Build()
            .GetValue<int>("Keycloak:JwksRefreshMinutes"));
        // The library adds Random.Next(refresh in seconds / 20) seconds.
        var maxJitter = TimeSpan.FromSeconds((int)refresh.TotalSeconds / 20 - 1);

        // Keycloak's default token lifetime (5 min) would end the old token around the refresh time; someone holding
        // the removed key can sign tokens of any lifetime, so this realm's tokens live 15 minutes.
        await Keycloak.AddRealmCopyAsync(Realm);
        await Keycloak.AdminAsync(HttpMethod.Put, $"/admin/realms/{Realm}", JsonSerializer.Serialize(new { accessTokenLifespan = 900 }));
        var oldToken = await Keycloak.UserTokenAsync("operator", realm: Realm);

        // The service reads the key list during its first request: somewhere between these two moments.
        var clock = Stopwatch.StartNew();
        Assert.Equal(HttpStatusCode.OK, (await ReadAsync(oldToken)).StatusCode);
        var readBy = clock.Elapsed;

        await Keycloak.ReplaceSigningKeyAsync(Realm);
        Assert.Equal(HttpStatusCode.OK, (await ReadAsync(oldToken)).StatusCode);
        var removedAt = clock.Elapsed;

        var lastAccepted = TimeSpan.Zero;
        TimeSpan? firstRefused = null;
        var giveUp = readBy + refresh + maxJitter + ReadAndAsk + TimeSpan.FromSeconds(30);
        while (firstRefused is null && clock.Elapsed < giveUp)
        {
            await Task.Delay(TimeSpan.FromSeconds(1));
            var status = (await ReadAsync(oldToken)).StatusCode;
            if (status == HttpStatusCode.OK)
                lastAccepted = clock.Elapsed;
            else if (status == HttpStatusCode.Unauthorized)
                firstRefused = clock.Elapsed;
            else
                Assert.Fail($"Unexpected {(int)status} at {clock.Elapsed.TotalSeconds:F1} s.");
        }

        output.WriteLine($"Key list read by {readBy.TotalSeconds:F1} s, key removed at {removedAt.TotalSeconds:F1} s");
        output.WriteLine($"Last accepted at {lastAccepted.TotalSeconds:F1} s, first refused at {firstRefused?.TotalSeconds:F1} s");
        output.WriteLine($"Refresh {refresh.TotalSeconds} s, random part up to {maxJitter.TotalSeconds} s");

        Assert.True(firstRefused is not null, $"The removed key was still accepted at {lastAccepted.TotalSeconds:F1} s.");
        // The list cannot have been read before the first request started, so the key is accepted at least that long.
        Assert.True(lastAccepted >= refresh, $"The removed key was refused already after {lastAccepted.TotalSeconds:F1} s.");
        Assert.True(firstRefused <= readBy + refresh + maxJitter + ReadAndAsk,
            $"The removed key was refused only at {firstRefused?.TotalSeconds:F1} s.");
    }

    private Task<HttpResponseMessage> ReadAsync(string token) => SendAsync(HttpMethod.Get, "/api/v1/invoices/summary", token);
}
