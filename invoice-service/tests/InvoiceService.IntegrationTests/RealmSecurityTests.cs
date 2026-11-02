using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using InvoiceService.IntegrationTests.Support;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// The realm file's sign-in rules, checked in the real Keycloak: a user is locked for a while after wrong passwords in a
/// row, the operations screen's client cannot get an offline token, and a refresh token can be used only once.
/// </summary>
[Collection(AuthCollection.Name)]
public class RealmSecurityTests(KeycloakFixture keycloak) : IDisposable
{
    private readonly HttpClient _http = new(new HttpClientHandler { AllowAutoRedirect = false });

    public void Dispose() => _http.Dispose();

    [Fact]
    public async Task After_five_wrong_passwords_in_a_row_the_right_password_is_refused_and_the_user_is_locked()
    {
        // A realm of its own: the locked user does not break the other tests.
        const string realm = "kilit-realm";
        await keycloak.AddRealmCopyAsync(realm);

        for (var attempt = 1; attempt <= 5; attempt++)
        {
            Assert.Equal(HttpStatusCode.BadRequest, (await PasswordGrantAsync(realm, "rolsuz", "yanlis-sifre")).StatusCode);
            // Keycloak has a separate rule for failures less than a second apart (quickLoginCheckMilliSeconds); waiting
            // longer makes this the count of wrong passwords (failureFactor).
            await Task.Delay(TimeSpan.FromMilliseconds(1100));
        }

        var right = await PasswordGrantAsync(realm, "rolsuz", KeycloakFixture.TestPassword("rolsuz"));
        Assert.Equal(HttpStatusCode.BadRequest, right.StatusCode);

        var users = await (await keycloak.AdminAsync(HttpMethod.Get, $"/admin/realms/{realm}/users?username=rolsuz&exact=true"))
            .Content.ReadFromJsonAsync<JsonElement>();
        var state = await (await keycloak.AdminAsync(HttpMethod.Get,
            $"/admin/realms/{realm}/attack-detection/brute-force/users/{users[0].GetProperty("id").GetString()}"))
            .Content.ReadFromJsonAsync<JsonElement>();
        Assert.True(state.GetProperty("disabled").GetBoolean());
        Assert.Equal(5, state.GetProperty("numFailures").GetInt32());
    }

    [Fact]
    public async Task The_operations_screen_asking_for_an_offline_token_is_refused()
    {
        var response = await _http.GetAsync($"{keycloak.BaseUrl}/realms/fatura/protocol/openid-connect/auth" +
            "?client_id=operasyon-ekrani&response_type=code&scope=openid%20offline_access" +
            "&redirect_uri=http%3A%2F%2Flocalhost%3A5100%2F&code_challenge=abcdefghijabcdefghijabcdefghijabcdefghij123" +
            "&code_challenge_method=S256");

        Assert.Equal(HttpStatusCode.Found, response.StatusCode);
        Assert.Contains("error=invalid_scope", response.Headers.Location!.Query);
    }

    [Fact]
    public async Task A_refresh_token_used_once_is_refused_the_second_time()
    {
        var tokens = await (await PasswordGrantAsync("fatura", "operator", KeycloakFixture.TestPassword("operator")))
            .Content.ReadFromJsonAsync<JsonElement>();
        var refreshToken = tokens.GetProperty("refresh_token").GetString()!;

        Assert.Equal(HttpStatusCode.OK, (await RefreshAsync(refreshToken)).StatusCode);
        var second = await RefreshAsync(refreshToken);

        Assert.Equal(HttpStatusCode.BadRequest, second.StatusCode);
        Assert.Equal("invalid_grant", (await second.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString());
    }

    private Task<HttpResponseMessage> PasswordGrantAsync(string realm, string user, string password) =>
        _http.PostAsync($"{keycloak.BaseUrl}/realms/{realm}/protocol/openid-connect/token", new FormUrlEncodedContent(
            new Dictionary<string, string>
            {
                ["grant_type"] = "password", ["client_id"] = "fatura-test", ["username"] = user, ["password"] = password
            }));

    private Task<HttpResponseMessage> RefreshAsync(string refreshToken) =>
        _http.PostAsync($"{keycloak.BaseUrl}/realms/fatura/protocol/openid-connect/token", new FormUrlEncodedContent(
            new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token", ["client_id"] = "fatura-test", ["refresh_token"] = refreshToken
            }));
}
