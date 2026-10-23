using InvoiceService.Api.Startup;
using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.Api.Tests;

public class CorsTests
{
    [Fact]
    public void Shipped_settings_name_the_operations_screen()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        var configuration = new ConfigurationBuilder().AddJsonFile(path).Build();
        var origins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()!;

        Assert.Empty(CorsExtensions.Validate(origins));
        Assert.Contains("http://localhost:5100", origins);
    }

    [Theory]
    [InlineData("http://localhost:5100")]
    [InlineData("https://ops.example.com")]
    public void A_scheme_host_and_port_is_a_valid_origin(string origin) =>
        Assert.Empty(CorsExtensions.Validate([origin]));

    [Theory]
    [InlineData("*")]
    [InlineData("localhost:5100")]
    [InlineData("http://localhost:5100/")]
    [InlineData("http://localhost:5100/ekran")]
    [InlineData("ftp://localhost")]
    public void Anything_else_is_refused(string origin) =>
        Assert.NotEmpty(CorsExtensions.Validate([origin]));

    [Fact]
    public void No_origin_at_all_is_refused() =>
        Assert.NotEmpty(CorsExtensions.Validate([]));

    [Fact]
    public void The_screen_may_send_the_token_in_authorization()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Cors:AllowedOrigins:0"] = "http://localhost:5100" })
            .Build();
        var services = new ServiceCollection().AddOperationsUiCors(configuration).BuildServiceProvider();

        var policy = services.GetRequiredService<IOptions<CorsOptions>>().Value.GetPolicy(CorsExtensions.PolicyName)!;

        Assert.Contains("Authorization", policy.Headers);
    }
}
