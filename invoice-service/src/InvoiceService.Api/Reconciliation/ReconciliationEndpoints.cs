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
            .WithSummary("One page of reconciliation runs, newest first")
            .WithDescription(
                "Without their findings. page starts at 1 (default 1), pageSize is 1 to 50 (default 20); the response carries " +
                "the page and the total number of runs. startedBy is the operator or Zamanlayıcı (the schedule); null for runs " +
                "made before it was recorded.")
            .Produces<ReconciliationRunListResponse>()
            .ProducesValidationProblem();

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

    private static async Task<IResult> ListRuns(int? page, int? pageSize, ReconciliationQueries queries, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        var (currentPage, size) = Paging.Read(
            page, pageSize, ReconciliationQueries.DefaultPageSize, ReconciliationQueries.MaxPageSize, errors);
        if (errors.Count > 0)
            return Results.ValidationProblem(errors);

        var (items, total) = await queries.ListRunsAsync(currentPage, size, ct);
        return Results.Ok(new ReconciliationRunListResponse(
            items.Select(ReconciliationRunResponse.From).ToList(), currentPage, size, total, Paging.TotalPages(total, size)));
    }

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
