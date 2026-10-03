using InvoiceService.Infrastructure.Erp;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Infrastructure.Tests;

public class ErpOptionsTests
{
    private static IConfiguration Settings(string? baseUrl = "http://erp-simulator:8080", string? timeout = "10") =>
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Erp:BaseUrl"] = baseUrl,
            ["Erp:TimeoutSeconds"] = timeout
        }).Build();

    private static ErpOptions Bind(IConfiguration configuration)
    {
        var options = new ErpOptions();
        configuration.GetSection(ErpOptions.SectionName).Bind(options);
        return options;
    }

    [Fact]
    public void Erp_settings_are_read_from_the_settings_file()
    {
        var configuration = Settings();
        var options = Bind(configuration);

        Assert.True(new ErpOptionsValidator(configuration).Validate(null, options).Succeeded);
        Assert.Equal(10, options.TimeoutSeconds);
    }

    [Theory]
    [InlineData(null, "10", "Erp:BaseUrl is missing")]
    [InlineData("http://erp-simulator:8080", null, "Erp:TimeoutSeconds is missing")]
    [InlineData("not a url", "10", "Erp:BaseUrl must be an absolute")]
    [InlineData("http://erp-simulator:8080", "0", "Erp:TimeoutSeconds must be greater than 0")]
    public void Invalid_erp_settings_are_rejected(string? baseUrl, string? timeout, string message)
    {
        var configuration = Settings(baseUrl, timeout);
        var result = new ErpOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains(message, result.FailureMessage);
    }
}
