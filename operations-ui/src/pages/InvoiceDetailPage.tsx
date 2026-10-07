import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { closeInvoiceFollowUp, openInvoiceFollowUp, resendInvoice } from '../api/endpoints'
import { detailsQuery } from '../api/queries'
import { failedStatus, maxFollowUpNoteLength, type InvoiceDetails } from '../api/types'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { RefreshStamp } from '../components/RefreshStamp'
import { StatusBadge } from '../components/StatusBadge'
import { StuckBadge } from '../components/StuckBadge'
import { emptyValue, formatAmount, formatDate, formatDateTime } from '../format'
import { describeFollowUpError, describeResendError, eventTypeLabel, tr } from '../tr'

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
  const [editingFollowUp, setEditingFollowUp] = useState(false)
  const [note, setNote] = useState('')
  const resend = useMutation({
    mutationFn: () => resendInvoice(invoice.invoiceNumber),
    // Başarıda da, reddedilmede de (örn. başkası göndermişse) faturanın gerçek durumu yeniden okunur.
    onSettled: () => queryClient.invalidateQueries(),
  })
  const openFollowUp = useMutation({
    mutationFn: () => openInvoiceFollowUp(invoice.invoiceNumber, note),
    onSettled: () => queryClient.invalidateQueries(),
    onSuccess: () => { setEditingFollowUp(false); setNote('') },
  })
  const closeFollowUp = useMutation({
    mutationFn: () => closeInvoiceFollowUp(invoice.invoiceNumber),
    onSettled: () => queryClient.invalidateQueries(),
  })

  return (
    <>
      <div className="headline">
        <StatusBadge status={invoice.status} />
        {invoice.stuck && <StuckBadge since={invoice.updatedAt} />}
        {data.followUp && <span className="badge badge-follow-up">{tr.details.followUpOpen(data.followUp.operatorName)}</span>}
        {invoice.stuck && data.followUp === null && !editingFollowUp && (
          <button type="button" onClick={() => setEditingFollowUp(true)}>{tr.details.takeFollowUp}</button>
        )}
        {data.followUp && <button type="button" disabled={closeFollowUp.isPending} onClick={() => closeFollowUp.mutate()}>{tr.details.closeFollowUp}</button>}
        {invoice.status === failedStatus && (
          <button type="button" className="primary" disabled={resend.isPending} onClick={() => resend.mutate()}>
            {resend.isPending ? tr.details.resending : tr.details.resend}
          </button>
        )}
      </div>
      {resend.isSuccess && <Notice kind="success">{tr.details.resendQueued}</Notice>}
      {resend.isError && <Notice kind="error">{describeResendError(resend.error)}</Notice>}
      {openFollowUp.isSuccess && <Notice kind="success">{tr.details.followUpOpened}</Notice>}
      {closeFollowUp.isSuccess && <Notice kind="success">{tr.details.followUpClosed}</Notice>}
      {openFollowUp.isError && <Notice kind="error">{describeFollowUpError(openFollowUp.error)}</Notice>}
      {closeFollowUp.isError && <Notice kind="error">{describeFollowUpError(closeFollowUp.error)}</Notice>}
      {editingFollowUp && (
        <form className="follow-up-form" onSubmit={(event) => { event.preventDefault(); openFollowUp.mutate() }}>
          <label htmlFor="follow-up-note">{tr.details.followUpNote}</label>
          <textarea id="follow-up-note" required maxLength={maxFollowUpNoteLength} value={note} onChange={(event) => setNote(event.target.value)} />
          <button className="primary" type="submit" disabled={openFollowUp.isPending || !note.trim()}>{tr.details.saveFollowUp}</button>
          <button type="button" onClick={() => { setEditingFollowUp(false); setNote('') }}>{tr.common.cancel}</button>
        </form>
      )}

      <h2>{tr.details.followUpSection}</h2>
      {data.followUp ? (
        <>
          {!invoice.stuck && <p className="muted">{tr.details.followUpNoLongerStuck}</p>}
          <dl className="facts">
            <dt>{tr.details.followUpFields.note}</dt><dd>{data.followUp.note}</dd>
            <dt>{tr.details.followUpFields.operator}</dt><dd>{data.followUp.operatorName}</dd>
            <dt>{tr.details.followUpFields.openedAt}</dt><dd>{formatDateTime(data.followUp.openedAt)}</dd>
          </dl>
        </>
      ) : data.followUps.length === 0 ? <p className="muted">{tr.details.noFollowUps}</p> : null}
      {data.followUps.length > 0 && (
        <>
          <h3>{tr.details.followUpHistory}</h3>
          <div className="table-wrap"><table>
            <thead><tr><th>{tr.details.followUpFields.note}</th><th>{tr.details.followUpFields.operator}</th><th>{tr.details.followUpFields.openedAt}</th><th>{tr.details.followUpFields.closedAt}</th><th>{tr.details.followUpFields.closedBy}</th></tr></thead>
            <tbody>{data.followUps.map((followUp) => <tr key={followUp.id}>
              <td>{followUp.note}</td><td>{followUp.operatorName}</td><td>{formatDateTime(followUp.openedAt)}</td>
              <td>{formatDateTime(followUp.closedAt)}</td><td>{followUp.closedBy ?? emptyValue}</td>
            </tr>)}</tbody>
          </table></div>
        </>
      )}

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
        <dt>{tr.details.fields.erpCheckedAt}</dt>
        <dd>{invoice.erpCheckedAt === null ? tr.details.neverChecked : formatDateTime(invoice.erpCheckedAt)}</dd>
        <dt>{tr.details.fields.erpCheckResult}</dt>
        <dd>{invoice.erpCheckResult ?? emptyValue}</dd>
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
