namespace InvoiceService.Domain.Operators;

/// <summary>
/// Who made an intervention, as the token says: the user name shown on the screen and the token's sub, which stays the
/// same when the user name is changed or given to someone else later. An intervention always comes with a sub; Sub is null
/// only in rows written before the sub was recorded.
/// </summary>
public sealed record OperatorIdentity(string Name, string? Sub);
