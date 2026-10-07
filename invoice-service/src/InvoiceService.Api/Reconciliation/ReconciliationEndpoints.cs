using InvoiceService.Api.Invoices;
using InvoiceService.Api.Operators;
using InvoiceService.Application.Reconciliation;

namespace InvoiceService.Api.Reconciliation;

public static class ReconciliationEndpoints
{
    public static IEndpointRouteBuilder MapReconciliationEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/reconciliation-runs").WithTags("Reconciliation");

        group.MapPost("/", StartRun)
            .WithName("StartReconciliationRun")
            .WithSummary("Start a reconciliation run now")
            .WithDescription(
                "Compares the service's invoices with the ERP's records, fixes what it can and reports the rest. Returns 202 with " +
                "the run (Çalışıyor); the run goes on in the background and is read with GET /api/v1/reconciliation-runs/{id}. " +
                "409 while another run is going, whether it was started by the schedule, by this endpoint or by another copy " +
                "of the service. " + InvoiceEndpoints.OperatorDescription + " The run keeps the name as startedBy.")
            .Produces<ReconciliationRunResponse>(StatusCodes.Status202Accepted)
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status409Conflict);

        group.MapGet("/", ListRuns)
            .WithName("ListReconciliationRuns")
            .WithSummary("The reconciliation runs, newest first")
            .WithDescription("Without their findings; every run is listed. startedBy is null for a run the schedule started.")
            .Produces<ReconciliationRunResponse[]>();

        group.MapGet("/{id:long}", GetRun)
            .WithName("GetReconciliationRun")
            .WithSummary("A reconciliation run with its findings")
            .Produces<ReconciliationRunDetailResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound);

        return app;
    }

    private static async Task<IResult> StartRun(
        HttpRequest request, ReconciliationService service, IHostApplicationLifetime lifetime, CancellationToken ct)
    {
        var (operatorName, invalid) = OperatorHeader.Read(request);
        if (invalid is not null)
            return invalid;

        var started = await service.TryStartAsync(operatorName, ct);
        if (started is null)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status409Conflict,
                title: "A reconciliation run is already going",
                detail: "Only one run at a time; try again when it has finished.",
                extensions: new Dictionary<string, object?> { ["code"] = ProblemCodes.ReconciliationRunning });
        }

        // Not tied to this request: the run goes on after the 202, and stops with the service.
        _ = Task.Run(() => service.ExecuteAsync(started, lifetime.ApplicationStopping));
        return Results.Accepted($"/api/v1/reconciliation-runs/{started.Run.Id}", ReconciliationRunResponse.From(started.Run));
    }

    private static async Task<IResult> ListRuns(ReconciliationQueries queries, CancellationToken ct) =>
        Results.Ok((await queries.ListRunsAsync(ct)).Select(ReconciliationRunResponse.From));

    private static async Task<IResult> GetRun(long id, ReconciliationQueries queries, CancellationToken ct)
    {
        var found = await queries.FindRunAsync(id, ct);
        if (found is null)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Reconciliation run not found",
                detail: $"No reconciliation run {id}.");
        }

        return Results.Ok(new ReconciliationRunDetailResponse(
            ReconciliationRunResponse.From(found.Value.Run),
            found.Value.Findings.Select(ReconciliationFindingResponse.From).ToList()));
    }
}
