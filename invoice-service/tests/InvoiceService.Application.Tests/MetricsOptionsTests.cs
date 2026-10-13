using InvoiceService.Application.Metrics;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Application.Tests;

public class MetricsOptionsTests
{
    private static Microsoft.Extensions.Options.ValidateOptionsResult Validate(string? seconds)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Metrics:DatabaseReadSeconds"] = seconds }).Build();
        var options = new MetricsOptions();
        configuration.GetSection(MetricsOptions.SectionName).Bind(options);
        return new MetricsOptionsValidator(configuration).Validate(null, options);
    }

    [Fact]
    public void A_positive_value_is_valid() => Assert.True(Validate("15").Succeeded);

    [Theory]
    [InlineData(null, "missing")]
    [InlineData("0", "greater than 0")]
    [InlineData("-1", "greater than 0")]
    public void A_missing_or_non_positive_value_stops_the_service(string? seconds, string reason)
    {
        var result = Validate(seconds);
        Assert.True(result.Failed);
        Assert.Contains(reason, result.FailureMessage);
    }
}
