import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router-dom'
import { startRun } from '../api/endpoints'
import { runDetailQuery, runsQuery } from '../api/queries'
import type { Finding, ReconciliationRun } from '../api/types'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { RefreshStamp } from '../components/RefreshStamp'
import { StatusBadge } from '../components/StatusBadge'
import { emptyValue, formatDateTime } from '../format'
import { describeStartRunError, tr } from '../tr'

const runsPageSize = 20

export function ReconciliationPage() {
  const [params, setParams] = useSearchParams()
  // Sayfa ve seçili çalışma adreste tutulur; seçilmemişse sayfanın en yenisi gösterilir.
  const page = Math.max(1, Number(params.get('sayfa')) || 1)
  const requestedId = Number(params.get('calisma')) || null
  const runs = useQuery(runsQuery(page, runsPageSize))
  const queryClient = useQueryClient()
  const start = useMutation({
    mutationFn: startRun,
    onSettled: () => queryClient.invalidateQueries(),
    // Yeni çalışma ilk sayfadadır.
    onSuccess: (run) => setParams({ calisma: String(run.id) }, { replace: true }),
  })

  function selectRun(id: number) {
    const next: Record<string, string> = { calisma: String(id) }
    if (page > 1) next.sayfa = String(page)
    setParams(next, { replace: true })
  }

  function goToPage(next: number) {
    setParams(next > 1 ? { sayfa: String(next) } : {}, { replace: true })
  }

  return (
    <>
      <h1>{tr.reconciliation.title}</h1>
      <div className="toolbar">
        <button type="button" className="primary" disabled={start.isPending} onClick={() => start.mutate()}>
          {start.isPending ? tr.reconciliation.starting : tr.reconciliation.runNow}
        </button>
      </div>
      {start.isSuccess && <Notice kind="success">{tr.reconciliation.started(start.data.id)}</Notice>}
      {start.isError && <Notice kind="error">{describeStartRunError(start.error)}</Notice>}
      <RefreshStamp query={runs} />

      <h2>{tr.reconciliation.runsSection}</h2>
      <QueryState query={runs}>
        {(data) =>
          data.items.length === 0 ? (
            <p className="muted">{data.totalCount === 0 ? tr.reconciliation.noRuns : tr.reconciliation.emptyPage}</p>
          ) : (
            <>
              <RunTable runs={data.items} selectedId={requestedId ?? data.items[0].id} onSelect={selectRun} />
              <div className="pager">
                <span>{tr.reconciliation.totalCount(data.totalCount)}</span>
                <button type="button" disabled={data.page <= 1} onClick={() => goToPage(data.page - 1)}>
                  {tr.invoices.previous}
                </button>
                <span>{tr.invoices.page(data.page, data.totalPages)}</span>
                <button type="button" disabled={data.page >= data.totalPages} onClick={() => goToPage(data.page + 1)}>
                  {tr.invoices.next}
                </button>
              </div>
              <Findings runId={requestedId ?? data.items[0].id} />
            </>
          )
        }
      </QueryState>
    </>
  )
}

interface RunTableProps {
  runs: ReconciliationRun[]
  selectedId: number
  onSelect: (id: number) => void
}

function RunTable({ runs, selectedId, onSelect }: RunTableProps) {
  const c = tr.reconciliation.runColumns
  return (
    <div className="table-wrap table-limited">
      <table>
        <thead>
          <tr>
            <th>{c.id}</th>
            <th>{c.startedAt}</th>
            <th>{c.finishedAt}</th>
            <th>{c.startedBy}</th>
            <th>{c.status}</th>
            <th className="num">{c.checked}</th>
            <th className="num">{c.fixed}</th>
            <th className="num">{c.reported}</th>
            <th>{c.error}</th>
          </tr>
        </thead>
        <tbody>
          {runs.map((run) => (
            <tr key={run.id} className={`clickable ${run.id === selectedId ? 'row-selected' : ''}`} onClick={() => onSelect(run.id)}>
              <td>
                <button type="button" className="link" onClick={() => onSelect(run.id)}>
                  {run.id}
                </button>
              </td>
              <td>{formatDateTime(run.startedAt)}</td>
              <td>{formatDateTime(run.finishedAt)}</td>
              <td title={run.startedBy === null ? tr.reconciliation.startedByUnknown : undefined}>{run.startedBy ?? emptyValue}</td>
              <td>
                <StatusBadge status={run.status} />
              </td>
              <td className="num">{run.checkedCount}</td>
              <td className="num">{run.fixedCount}</td>
              <td className="num">{run.reportedCount}</td>
              <td>{run.error ?? emptyValue}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// Raporlananlar (incelenmesi gerekenler) düzeltilenlerden ayrı ve önce gösterilir.
function Findings({ runId }: { runId: number }) {
  const detail = useQuery(runDetailQuery(runId))

  return (
    <>
      <h2>{tr.reconciliation.findingsSection(runId)}</h2>
      <QueryState query={detail}>
        {(data) => (
          <>
            {data.run.status === 'Çalışıyor' && <Notice kind="info">{tr.reconciliation.runningNote}</Notice>}
            <FindingGroup
              title={tr.reconciliation.reportedSection}
              hint={tr.reconciliation.reportedHint}
              empty={tr.reconciliation.noReported}
              findings={data.findings.filter((f) => f.action === 'Raporlandı')}
              emphasised
            />
            <FindingGroup
              title={tr.reconciliation.fixedSection}
              hint={tr.reconciliation.fixedHint}
              empty={tr.reconciliation.noFixed}
              findings={data.findings.filter((f) => f.action === 'Düzeltildi')}
            />
          </>
        )}
      </QueryState>
    </>
  )
}

interface GroupProps {
  title: string
  hint: string
  empty: string
  findings: Finding[]
  emphasised?: boolean
}

function FindingGroup({ title, hint, empty, findings, emphasised }: GroupProps) {
  const c = tr.reconciliation.findingColumns
  return (
    <section className={emphasised ? 'findings findings-reported' : 'findings'}>
      <h3>
        {title} ({findings.length})
      </h3>
      <p className="muted small">{hint}</p>
      {findings.length === 0 ? (
        <p className="muted">{empty}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{c.invoiceNumber}</th>
                <th>{c.type}</th>
                <th>{c.details}</th>
                <th>{c.createdAt}</th>
              </tr>
            </thead>
            <tbody>
              {findings.map((finding) => (
                <tr key={finding.id}>
                  <td>
                    {/* Serviste olmayan faturanın detay sayfası yoktur. */}
                    {finding.findingType === 'Serviste Yok' ? (
                      finding.invoiceNumber
                    ) : (
                      <Link to={`/faturalar/${encodeURIComponent(finding.invoiceNumber)}`}>{finding.invoiceNumber}</Link>
                    )}
                  </td>
                  <td>{finding.findingType}</td>
                  <td>{finding.details}</td>
                  <td>{formatDateTime(finding.createdAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
