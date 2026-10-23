using InvoiceService.Api.Auth;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.Api.Tests;

public class KeycloakSettingsTests
{
    [Fact]
    public void Every_missing_value_is_reported()
    {
        Assert.Equal(4, new KeycloakSettings().Validate().Count);
    }

    [Fact]
    public void A_base_url_that_is_not_http_is_reported()
    {
        var settings = new KeycloakSettings
        {
            BaseUrl = "keycloak:8080", Realm = "fatura", Audience = "fatura-servisi", ClockSkewSeconds = 30
        };
        Assert.Single(settings.Validate());
    }

    [Fact]
    public void A_negative_clock_skew_is_reported()
    {
        var settings = new KeycloakSettings
        {
            BaseUrl = "http://localhost:8080", Realm = "fatura", Audience = "fatura-servisi", ClockSkewSeconds = -1
        };
        Assert.Single(settings.Validate());
    }

    [Fact]
    public void The_clock_skew_comes_from_the_settings()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Keycloak:BaseUrl"] = "http://localhost:8080",
                ["Keycloak:Realm"] = "fatura",
                ["Keycloak:Audience"] = "fatura-servisi",
                ["Keycloak:ClockSkewSeconds"] = "30",
            })
            .Build();
        var services = new ServiceCollection().AddKeycloakAuth(configuration).BuildServiceProvider();

        var options = services.GetRequiredService<IOptionsMonitor<JwtBearerOptions>>()
            .Get(JwtBearerDefaults.AuthenticationScheme);

        Assert.Equal(TimeSpan.FromSeconds(30), options.TokenValidationParameters.ClockSkew);
    }
}
