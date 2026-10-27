using InvoiceService.Api.Auth;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace InvoiceService.Api.Tests;

public class KeycloakSettingsTests
{
    [Fact]
    public void Every_missing_value_is_reported()
    {
        Assert.Equal(5, new KeycloakSettings().Validate().Count);
    }

    [Fact]
    public void A_base_url_that_is_not_http_is_reported()
    {
        var settings = new KeycloakSettings
        {
            BaseUrl = "keycloak:8080", Realm = "fatura", Audience = "fatura-servisi", ClockSkewSeconds = 30,
            JwksRefreshMinutes = 5
        };
        Assert.Single(settings.Validate());
    }

    [Fact]
    public void A_negative_clock_skew_is_reported()
    {
        var settings = new KeycloakSettings
        {
            BaseUrl = "http://localhost:8080", Realm = "fatura", Audience = "fatura-servisi", ClockSkewSeconds = -1,
            JwksRefreshMinutes = 5
        };
        Assert.Single(settings.Validate());
    }

    [Fact]
    public void A_key_refresh_below_the_library_minimum_is_reported()
    {
        var settings = new KeycloakSettings
        {
            BaseUrl = "http://localhost:8080", Realm = "fatura", Audience = "fatura-servisi", ClockSkewSeconds = 30,
            JwksRefreshMinutes = 4
        };
        Assert.Single(settings.Validate());
    }

    [Fact]
    public void The_clock_skew_and_the_key_refresh_come_from_the_settings()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Keycloak:BaseUrl"] = "http://localhost:8080",
                ["Keycloak:Realm"] = "fatura",
                ["Keycloak:Audience"] = "fatura-servisi",
                ["Keycloak:ClockSkewSeconds"] = "30",
                ["Keycloak:JwksRefreshMinutes"] = "5",
            })
            .Build();
        var services = new ServiceCollection().AddKeycloakAuth(configuration).BuildServiceProvider();

        var options = services.GetRequiredService<IOptionsMonitor<JwtBearerOptions>>()
            .Get(JwtBearerDefaults.AuthenticationScheme);

        Assert.Equal(TimeSpan.FromSeconds(30), options.TokenValidationParameters.ClockSkew);
        // The configuration manager, which reads the keys, gets the value; not only the options.
        Assert.Equal(TimeSpan.FromMinutes(5), ((BaseConfigurationManager)options.ConfigurationManager!).AutomaticRefreshInterval);
    }
}
