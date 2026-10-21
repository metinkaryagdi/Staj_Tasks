using InvoiceService.Api.Auth;

namespace InvoiceService.Api.Tests;

public class KeycloakSettingsTests
{
    [Fact]
    public void Every_missing_value_is_reported()
    {
        Assert.Equal(3, new KeycloakSettings().Validate().Count);
    }

    [Fact]
    public void A_base_url_that_is_not_http_is_reported()
    {
        var settings = new KeycloakSettings { BaseUrl = "keycloak:8080", Realm = "fatura", Audience = "fatura-servisi" };
        Assert.Single(settings.Validate());
    }
}