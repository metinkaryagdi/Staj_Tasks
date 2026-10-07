import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import { resendInvoice } from '../api/endpoints'
import { detailsQuery } from '../api/queries'
import { failedStatus, type InvoiceDetails } from '../api/types'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { RefreshStamp } from '../components/RefreshStamp'
import { StatusBadge } from '../components/StatusBadge'
import { emptyValue, formatAmount, formatDate, formatDateTime } from '../format'
import { describeResendError, eventTypeLabel, tr } from '../tr'

export function InvoiceDetailPage() {
  const { invoiceNumber = '' } = useParams()
  const details = useQuery(detailsQuery(invoiceNumber))

  return (
    <>
      <p>
        <Link to="/faturalar">{tr.details.back}</Link>
      </p>
      <h1>{invoiceNumber}</h1>
      <RefreshStamp query={details} />
      <QueryState query={details}>{(data) => <Details data={data} />}</QueryState>
    </>
  )
}

function Details({ data }: { data: InvoiceDetails }) {
  const { invoice, outbox, events, findings, operatorActions } = data
  const queryClient = useQueryClient()
  const resend = useMutation({
    mutationFn: () => resendInvoice(invoice.invoiceNumber),
    // Başarıda da, reddedilmede de (örn. başkası göndermişse) faturanın gerçek durumu yeniden okunur.
    onSettled: () => queryClient.invalidateQueries(),
  })

  return (
    <>
      <div className="headline">
        <StatusBadge status={invoice.status} />
        {invoice.status === failedStatus && (
          <button type="button" className="primary" disabled={resend.isPending} onClick={() => resend.mutate()}>
            {resend.isPending ? tr.details.resending : tr.details.resend}
          </button>
        )}
      </div>
      {resend.isSuccess && <Notice kind="success">{tr.details.resendQueued}</Notice>}
      {resend.isError && <Notice kind="error">{describeResendError(resend.error)}</Notice>}

      <h2>{tr.details.invoiceSection}</h2>
      <dl className="facts">
        <dt>{tr.details.fields.customerCode}</dt>
        <dd>{invoice.customerCode}</dd>
        <dt>{tr.details.fields.amount}</dt>
        <dd>{formatAmount(invoice.amount, invoice.currency)}</dd>
        <dt>{tr.details.fields.invoiceDate}</dt>
        <dd>{formatDate(invoice.invoiceDate)}</dd>
        <dt>{tr.details.fields.status}</dt>
        <dd>{invoice.status}</dd>
        <dt>{tr.details.fields.erpReference}</dt>
        <dd>{invoice.erpReference ?? emptyValue}</dd>
        <dt>{tr.details.fields.rejectReason}</dt>
        <dd>{invoice.rejectReason ?? emptyValue}</dd>
        <dt>{tr.details.fields.lastError}</dt>
        <dd>{invoice.lastError ?? emptyValue}</dd>
        <dt>{tr.details.fields.attempts}</dt>
        <dd>{invoice.sendAttemptCount}</dd>
        <dt>{tr.details.fields.createdAt}</dt>
        <dd>{formatDateTime(invoice.createdAt)}</dd>
        <dt>{tr.details.fields.updatedAt}</dt>
        <dd>{formatDateTime(invoice.updatedAt)}</dd>
      </dl>

      <h2>{tr.details.outboxSection}</h2>
      {outbox === null ? (
        <p className="muted">{tr.details.noOutbox}</p>
      ) : (
        <dl className="facts">
          <dt>{tr.details.outbox.status}</dt>
          <dd>
            <StatusBadge status={outbox.status} />
          </dd>
          <dt>{tr.details.outbox.attempts}</dt>
          <dd>{outbox.attemptCount}</dd>
          <dt>{tr.details.outbox.nextAttempt}</dt>
          <dd>{outbox.status === 'Bekliyor' ? formatDateTime(outbox.nextAttemptAt) : tr.details.outbox.nextAttemptDone}</dd>
          <dt>{tr.details.outbox.lastError}</dt>
          <dd>{outbox.lastError ?? emptyValue}</dd>
          <dt>{tr.details.outbox.createdAt}</dt>
          <dd>{formatDateTime(outbox.createdAt)}</dd>
          <dt>{tr.details.outbox.processedAt}</dt>
          <dd>{formatDateTime(outbox.processedAt)}</dd>
        </dl>
      )}

      <h2>{tr.details.eventsSection}</h2>
      {events.length === 0 ? (
        <p className="muted">{tr.details.noEvents}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{tr.details.events.eventId}</th>
                <th>{tr.details.events.type}</th>
                <th>{tr.details.events.status}</th>
                <th>{tr.details.events.ignoreReason}</th>
                <th className="num">{tr.details.events.deliveryCount}</th>
                <th>{tr.details.events.occurredAt}</th>
                <th>{tr.details.events.receivedAt}</th>
                <th>{tr.details.events.processedAt}</th>
              </tr>
            </thead>
            <tbody>
              {events.map((event) => (
                <tr key={event.eventId}>
                  <td className="mono">{event.eventId}</td>
                  <td title={event.eventType}>{eventTypeLabel(event.eventType)}</td>
                  <td>
                    <StatusBadge status={event.status} />
                  </td>
                  <td>{event.ignoreReason ?? emptyValue}</td>
                  <td className="num">{event.deliveryCount}</td>
                  <td>{formatDateTime(event.occurredAt)}</td>
                  <td>{formatDateTime(event.receivedAt)}</td>
                  <td>{formatDateTime(event.processedAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <h2>{tr.details.findingsSection}</h2>
      {findings.length === 0 ? (
        <p className="muted">{tr.details.noFindings}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{tr.details.findings.run}</th>
                <th>{tr.details.findings.type}</th>
                <th>{tr.details.findings.action}</th>
                <th>{tr.details.findings.details}</th>
                <th>{tr.details.findings.createdAt}</th>
              </tr>
            </thead>
            <tbody>
              {findings.map((finding) => (
                <tr key={finding.id}>
                  <td>
                    <Link to={`/mutabakat?calisma=${finding.runId}`}>{finding.runId}</Link>
                  </td>
                  <td>{finding.findingType}</td>
                  <td>
                    <StatusBadge status={finding.action} />
                  </td>
                  <td>{finding.details}</td>
                  <td>{formatDateTime(finding.createdAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <h2>{tr.details.actionsSection}</h2>
      {operatorActions.length === 0 ? (
        <p className="muted">{tr.details.noActions}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{tr.details.actions.createdAt}</th>
                <th>{tr.details.actions.operator}</th>
                <th>{tr.details.actions.action}</th>
                <th>{tr.details.actions.result}</th>
              </tr>
            </thead>
            <tbody>
              {operatorActions.map((action, index) => (
                <tr key={index}>
                  <td>{formatDateTime(action.createdAt)}</td>
                  <td>{action.operatorName}</td>
                  <td>{action.action}</td>
                  <td>{action.result}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  )
}
