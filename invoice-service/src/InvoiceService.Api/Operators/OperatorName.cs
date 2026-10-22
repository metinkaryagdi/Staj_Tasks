using System.Security.Claims;
using InvoiceService.Api.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Api.Operators;

/// <summary>
/// Who makes a change: the user name in the token (preferred_username), so the change is recorded under the name Keycloak
/// signed. A name sent in the request (a header, the query or the body) is not read.
/// </summary>
public static class OperatorName
{
    public const string ClaimType = "preferred_username";

    /// <summary>The user name, or the 403 to answer with when the token carries no usable one.</summary>
    public static (string? Name, IResult? Error) Read(ClaimsPrincipal user)
    {
        var name = user.FindFirst(ClaimType)?.Value.Trim();
        if (string.IsNullOrEmpty(name))
            return (null, Forbidden(ProblemCodes.OperatorNameRequired,
                $"The token carries no {ClaimType}; the change cannot be recorded under a name."));
        if (name.Length > OperatorAction.MaxNameLength)
            return (null, Forbidden(ProblemCodes.OperatorNameInvalid,
                $"The token's {ClaimType} is longer than {OperatorAction.MaxNameLength} characters."));

        return (name, null);
    }

    private static IResult Forbidden(string code, string detail) => Results.Problem(
        statusCode: StatusCodes.Status403Forbidden,
        title: "No usable user name in the token",
        detail: detail,
        extensions: new Dictionary<string, object?> { ["code"] = code });
}