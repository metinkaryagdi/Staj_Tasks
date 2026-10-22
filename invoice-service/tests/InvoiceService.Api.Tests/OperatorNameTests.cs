using System.Security.Claims;
using InvoiceService.Api.Operators;
using InvoiceService.Domain.Operators;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;

namespace InvoiceService.Api.Tests;

public class OperatorNameTests
{
    private static ClaimsPrincipal User(params Claim[] claims) => new(new ClaimsIdentity(claims, "test"));

    [Fact]
    public void The_name_is_the_tokens_preferred_username()
    {
        var (name, error) = OperatorName.Read(User(new Claim(OperatorName.ClaimType, "operator")));

        Assert.Equal("operator", name);
        Assert.Null(error);
    }

    [Fact]
    public void A_token_without_a_user_name_is_refused_with_403()
    {
        var (name, error) = OperatorName.Read(User(new Claim("sub", "1d547fb7")));

        Assert.Null(name);
        Assert.Equal(StatusCodes.Status403Forbidden, Assert.IsType<ProblemHttpResult>(error).StatusCode);
    }

    [Fact]
    public void A_user_name_longer_than_the_column_is_refused_with_403()
    {
        var tooLong = new string('a', OperatorAction.MaxNameLength + 1);

        var (_, error) = OperatorName.Read(User(new Claim(OperatorName.ClaimType, tooLong)));

        Assert.Equal(StatusCodes.Status403Forbidden, Assert.IsType<ProblemHttpResult>(error).StatusCode);
    }
}
