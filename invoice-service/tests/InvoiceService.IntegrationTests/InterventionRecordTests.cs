using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using InvoiceService.IntegrationTests.Support;
using Microsoft.IdentityModel.JsonWebTokens;
using Npgsql;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// An intervention is recorded under the user name and the sub of the operator's real Keycloak token; with a token that
/// carries no sub it is refused and nothing is recorded.
/// </summary>
public class InterventionRecordTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    private const string ResendPath = "/api/v1/invoices/FTR-999999/resend";

    [Fact]
    public async Task An_intervention_is_recorded_with_the_tokens_user_name_and_sub()
    {
        var token = await Keycloak.UserTokenAsync("operator");

        // The invoice does not exist; the refused request is recorded all the same.
        Assert.Equal(HttpStatusCode.NotFound, (await SendAsync(HttpMethod.Post, ResendPath, token)).StatusCode);

        Assert.Equal(new JsonWebToken(token).Subject, await ScalarAsync<string>(
            "SELECT operator_sub FROM operator_actions WHERE invoice_number = 'FTR-999999' AND operator_name = 'operator'"));
    }

    [Fact]
    public async Task An_intervention_with_a_token_without_a_sub_is_refused_and_not_recorded()
    {
        // Keycloak 26 puts the sub into the token through the "basic" client scope; this copy of the test client has the
        // other default scopes (user name, roles) but not that one.
        await Keycloak.AddTestClientAsync("fatura-test-subsuz",
            client => client["defaultClientScopes"] = new JsonArray("profile", "email", "roles", "web-origins", "acr"));
        var token = await Keycloak.UserTokenAsync("operator", "fatura-test-subsuz");
        Assert.False(new JsonWebToken(token).TryGetPayloadValue<string>("sub", out _), "The token was expected to have no sub.");

        var response = await SendAsync(HttpMethod.Post, ResendPath, token);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("operator_sub_required", problem.GetProperty("code").GetString());
        Assert.Equal(0L, await ScalarAsync<long>("SELECT count(*) FROM operator_actions"));
    }

    private async Task<T?> ScalarAsync<T>(string sql)
    {
        await using var connection = new NpgsqlConnection(ConnectionString);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        var result = await command.ExecuteScalarAsync();
        return result is null or DBNull ? default : (T)result;
    }
}
