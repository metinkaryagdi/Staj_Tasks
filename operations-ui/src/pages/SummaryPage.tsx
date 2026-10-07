import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { runsQuery, summaryQuery } from '../api/queries'
import { stuckFilter, type ReconciliationRun } from '../api/types'
import { QueryState } from '../components/QueryState'
import { RefreshStamp } from '../components/RefreshStamp'
import { StatusBadge } from '../components/StatusBadge'
import { emptyValue, formatDateTime } from '../format'
import { tr } from '../tr'

export function SummaryPage() {
  const summary = useQuery(summaryQuery())
  const runs = useQuery(runsQuery())

  return (
    <>
      <h1>{tr.summary.title}</h1>
      <RefreshStamp query={summary} />

      <QueryState query={summary}>
        {(data) => (
          <>
            <h2>{tr.summary.statusCounts}</h2>
            <div className="cards">
              {data.counts.map((item) => (
                <Link key={item.status} to={`/faturalar?durum=${encodeURIComponent(item.status)}`} className="card card-link">
                  <StatusBadge status={item.status} />
                  <span className="card-value">{item.count}</span>
                </Link>
              ))}
            </div>

            <div className="cards">
              <div className="card">
                <span className="card-label">{tr.summary.total}</span>
                <span className="card-value">{data.total}</span>
              </div>
              <Link
                to={`/faturalar?durum=${encodeURIComponent(stuckFilter)}`}
                className={`card card-link ${data.stuckCount > 0 ? 'card-alert' : ''}`}
              >
                <span className="card-label">{tr.summary.stuck}</span>
                <span className="card-value">{data.stuckCount}</span>
                <span className="muted small">{tr.summary.stuckHint(data.stuckAfterMinutes)}</span>
              </Link>
            </div>
          </>
        )}
      </QueryState>

      <h2>{tr.summary.lastRun}</h2>
      <QueryState query={runs}>{(data) => (data.length === 0 ? <p className="muted">{tr.summary.noRun}</p> : <LastRun run={data[0]} />)}</QueryState>
    </>
  )
}

function LastRun({ run }: { run: ReconciliationRun }) {
  const running = run.status === 'Çalışıyor'
  return (
    <div className="card card-wide">
      <dl className="facts">
        <dt>{tr.summary.runNumber}</dt>
        <dd>{run.id}</dd>
        <dt>{tr.summary.runStatus}</dt>
        <dd>
          <StatusBadge status={run.status} />
        </dd>
        <dt>{tr.summary.started}</dt>
        <dd>{formatDateTime(run.startedAt)}</dd>
        <dt>{tr.summary.finished}</dt>
        <dd>{formatDateTime(run.finishedAt)}</dd>
        {running ? (
          <>
            <dt />
            <dd className="muted">{tr.summary.stillRunning}</dd>
          </>
        ) : (
          <>
            <dt>{tr.summary.checked}</dt>
            <dd>{run.checkedCount}</dd>
            <dt>{tr.summary.fixed}</dt>
            <dd>{run.fixedCount}</dd>
            <dt>{tr.summary.reported}</dt>
            <dd className={run.reportedCount > 0 ? 'text-warn' : ''}>{run.reportedCount}</dd>
          </>
        )}
        <dt>{tr.summary.error}</dt>
        <dd>{run.error ?? emptyValue}</dd>
      </dl>
      <Link to="/mutabakat">{tr.summary.openReconciliation}</Link>
    </div>
  )
}
