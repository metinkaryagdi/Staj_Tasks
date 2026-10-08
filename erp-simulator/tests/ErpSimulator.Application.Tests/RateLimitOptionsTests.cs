using ErpSimulator.Application.Simulation;
using Microsoft.Extensions.Configuration;

namespace ErpSimulator.Application.Tests;

public class RateLimitOptionsTests
{
    private static (IConfiguration Configuration, RateLimitOptions Options) Settings(string? permitsPerSecond)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["RateLimit:PermitsPerSecond"] = permitsPerSecond })
            .Build();
        var options = new RateLimitOptions();
        configuration.GetSection(RateLimitOptions.SectionName).Bind(options);
        return (configuration, options);
    }

    [Fact]
    public void Validator_accepts_a_positive_limit()
    {
        var (configuration, options) = Settings("20");

        var result = new RateLimitOptionsValidator(configuration).Validate(null, options);

        Assert.True(result.Succeeded);
        Assert.Equal(20, options.PermitsPerSecond);
    }

    [Fact]
    public void Validator_rejects_a_missing_limit()
    {
        var (configuration, options) = Settings(null);

        var result = new RateLimitOptionsValidator(configuration).Validate(null, options);

        Assert.True(result.Failed);
        Assert.Contains("RateLimit:PermitsPerSecond is missing", result.FailureMessage);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5")]
    public void Validator_rejects_a_limit_that_is_not_positive(string value)
    {
        var (configuration, options) = Settings(value);

        var result = new RateLimitOptionsValidator(configuration).Validate(null, options);

        Assert.True(result.Failed);
        Assert.Contains("must be greater than 0", result.FailureMessage);
    }
}
