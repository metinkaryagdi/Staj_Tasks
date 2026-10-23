using System.Security.Claims;
using InvoiceService.Api.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Api.Operators;

/// <summary>
/// Who makes a change: the user name (preferred_username) and the sub in the token, so the change is recorded under the
/// identity Keycloak signed. The name is what the screen shows; the sub stays the same when the name is changed or later
/// given to someone else. A name sent in the request (a header, the query or the body) is not read.
/// </summary>
public static class OperatorName
{
    public const string ClaimType = "preferred_username";
    public const string SubClaimType = "sub";

    /// <summary>The user name and the sub (null if the token carries none), or the 403 to answer with when the token
    /// carries no usable name.</summary>
    public static (OperatorIdentity? Operator, IResult? Error) Read(ClaimsPrincipal user)
    {
        var name = user.FindFirst(ClaimType)?.Value.Trim();
        if (string.IsNullOrEmpty(name))
            return (null, Forbidden(ProblemCodes.OperatorNameRequired,
                $"The token carries no {ClaimType}; the change cannot be recorded under a name."));
        if (name.Length > OperatorAction.MaxNameLength)
            return (null, Forbidden(ProblemCodes.OperatorNameInvalid,
                $"The token's {ClaimType} is longer than {OperatorAction.MaxNameLength} characters."));

        return (new OperatorIdentity(name, user.FindFirst(SubClaimType)?.Value), null);
    }

    private static IResult Forbidden(string code, string detail) => Results.Problem(
        statusCode: StatusCodes.Status403Forbidden,
        title: "No usable user name in the token",
        detail: detail,
        extensions: new Dictionary<string, object?> { ["code"] = code });
}