namespace InvoiceService.Api.Auth;

/// <summary>The realm roles of keycloak/fatura-realm.json.</summary>
public static class Roles
{
    public const string Viewer = "fatura-izleyici";
    public const string Operator = "fatura-operatoru";
    public const string InvoiceCreator = "fatura-olusturucu";
}

/// <summary>The rules the endpoints ask for.</summary>
public static class Policies
{
    /// <summary>Reading invoices and reconciliation runs: viewer or operator.</summary>
    public const string Read = "Read";

    /// <summary>Resend, bulk resend, starting a reconciliation run, follow-up: operator only.</summary>
    public const string Intervene = "Intervene";

    /// <summary>POST /api/v1/invoices: the order system only.</summary>
    public const string CreateInvoice = "CreateInvoice";
}