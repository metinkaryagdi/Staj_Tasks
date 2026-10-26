using System.Security.Claims;
using InvoiceService.Api.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Api.Operators;

/// <summary>
/// Who makes a change: the user name (preferred_username) and the sub in the token, so the change is recorded under the
/// identity Keycloak signed. The name is what the screen shows; the sub stays the same when the name is changed or later
/// given to someone else. A name sent in the request (a header, the query or the body) is not read. A token without a sub
/// is refused: the change could not be traced to the user later.
/// </summary>
public static class OperatorName
{
    public const string ClaimType = "preferred_username";
    public const string SubClaimType = "sub";

    /// <summary>The user name and the sub, or the 403 to answer with when the token carries no usable name or no
    /// sub.</summary>
    public static (OperatorIdentity? Operator, IResult? Error) Read(ClaimsPrincipal user)
    {
        var name = user.FindFirst(ClaimType)?.Value.Trim();
        if (string.IsNullOrEmpty(name))
            return (null, Forbidden(NoName, ProblemCodes.OperatorNameRequired,
                $"The token carries no {ClaimType}; the change cannot be recorded under a name."));
        if (name.Length > OperatorAction.MaxNameLength)
            return (null, Forbidden(NoName, ProblemCodes.OperatorNameInvalid,
                $"The token's {ClaimType} is longer than {OperatorAction.MaxNameLength} characters."));

        var sub = user.FindFirst(SubClaimType)?.Value.Trim();
        if (string.IsNullOrWhiteSpace(sub))
            return (null, Forbidden("No sub in the token", ProblemCodes.OperatorSubRequired,
                $"The token carries no {SubClaimType}; the change cannot be recorded under an identity that does not change."));

        return (new OperatorIdentity(name, sub), null);
    }

    private const string NoName = "No usable user name in the token";

    private static IResult Forbidden(string title, string code, string detail) => Results.Problem(
        statusCode: StatusCodes.Status403Forbidden,
        title: title,
        detail: detail,
        extensions: new Dictionary<string, object?> { ["code"] = code });
}