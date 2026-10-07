using InvoiceService.Api.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Api.Operators;

/// <summary>
/// The X-Operator-Name header: the name the person typed into the operations screen, so the change is recorded under
/// it. Not authentication; anyone can send any name. Browsers send only Latin-1 in a header, so the screen sends the name
/// percent-encoded (encodeURIComponent) and it is decoded here; a plain ASCII name works as it is.
/// </summary>
public static class OperatorHeader
{
    public const string Name = "X-Operator-Name";

    /// <summary>The decoded name, or the 400 to answer with when the header is missing, empty or not a usable name.</summary>
    public static (string? Name, IResult? Error) Read(HttpRequest request)
    {
        var values = request.Headers[Name];
        if (values.Count > 1)
            return (null, Invalid(ProblemCodes.OperatorNameInvalid, $"Send {Name} once."));

        var name = Uri.UnescapeDataString(values.ToString()).Trim();
        if (name.Length == 0)
            return (null, Invalid(ProblemCodes.OperatorNameRequired, $"{Name} is required: the name of the person making the change."));
        if (name.Length > OperatorAction.MaxNameLength)
            return (null, Invalid(ProblemCodes.OperatorNameInvalid, $"{Name} must be at most {OperatorAction.MaxNameLength} characters."));
        if (name.Any(char.IsControl))
            return (null, Invalid(ProblemCodes.OperatorNameInvalid, $"{Name} must not contain control characters."));

        return (name, null);
    }

    private static IResult Invalid(string code, string message) => Results.ValidationProblem(
        new Dictionary<string, string[]> { [Name] = [message] },
        extensions: new Dictionary<string, object?> { ["code"] = code });
}
