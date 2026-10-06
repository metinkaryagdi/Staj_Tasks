import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router-dom'
import { resendInvoices } from '../api/endpoints'
import { invoicesQuery } from '../api/queries'
import { failedStatus, invoiceStatuses, type Invoice, type InvoiceQuery, type InvoiceStatus, type ResendItem } from '../api/types'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { RefreshStamp } from '../components/RefreshStamp'
import { StatusBadge } from '../components/StatusBadge'
import { emptyValue, formatAmount, formatDateTime } from '../format'
import { deselectMany, maxSelection, selectMany, toggle } from '../selection'
import { describeResendError, describeResendRefusal, tr } from '../tr'

const pageSizes = [20, 50, 100]

// Süzgeç, arama ve sayfa adreste tutulur: yenileyince ya da geri dönünce aynı liste açılır.
function readQuery(params: URLSearchParams): InvoiceQuery {
  const status = params.get('durum') ?? ''
  const pageSize = Number(params.get('boyut'))
  return {
    status: (invoiceStatuses as readonly string[]).includes(status) ? (status as InvoiceStatus) : '',
    search: params.get('ara') ?? '',
    page: Math.max(1, Number(params.get('sayfa')) || 1),
    pageSize: pageSizes.includes(pageSize) ? pageSize : pageSizes[0],
  }
}

export function InvoiceListPage() {
  const [params, setParams] = useSearchParams()
  const query = readQuery(params)
  const list = useQuery(invoicesQuery(query))
  const queryClient = useQueryClient()

  const [searchText, setSearchText] = useState(query.search)
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set())
  const [limitReached, setLimitReached] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [report, setReport] = useState<ResendItem[] | null>(null)

  function update(changes: Partial<InvoiceQuery>) {
    const next = { ...query, ...changes }
    const nextParams = new URLSearchParams()
    if (next.status) nextParams.set('durum', next.status)
    if (next.search) nextParams.set('ara', next.search)
    if (next.page > 1) nextParams.set('sayfa', String(next.page))
    if (next.pageSize !== pageSizes[0]) nextParams.set('boyut', String(next.pageSize))
    setParams(nextParams, { replace: true })
  }

  // Yazarken her tuşta istek atılmasın: arama kutusu durunca süzgece işlenir.
  useEffect(() => {
    if (searchText === query.search) return
    const timer = setTimeout(() => update({ search: searchText.trim(), page: 1 }), 400)
    return () => clearTimeout(timer)
  }, [searchText])

  const resend = useMutation({
    mutationFn: resendInvoices,
    onSuccess: (results) => {
      setReport(results)
      setSelected(new Set())
      setConfirming(false)
      void queryClient.invalidateQueries()
    },
    onError: () => setConfirming(false),
  })

  function choose(change: { selected: Set<string>; limitReached: boolean }) {
    setSelected(change.selected)
    setLimitReached(change.limitReached)
    setConfirming(false)
  }

  function clearSelection() {
    setSelected(new Set())
    setLimitReached(false)
    setConfirming(false)
  }

  return (
    <>
      <h1>{tr.invoices.title}</h1>

      <div className="toolbar">
        <label>
          {tr.invoices.statusFilter}
          <select value={query.status} onChange={(e) => update({ status: e.target.value as InvoiceStatus | '', page: 1 })}>
            <option value="">{tr.invoices.allStatuses}</option>
            {invoiceStatuses.map((status) => (
              <option key={status} value={status}>
                {status}
              </option>
            ))}
          </select>
        </label>
        <label>
          {tr.invoices.search}
          <input
            type="search"
            value={searchText}
            placeholder={tr.invoices.searchPlaceholder}
            onChange={(e) => setSearchText(e.target.value)}
          />
        </label>
        <label>
          {tr.invoices.pageSize}
          <select value={query.pageSize} onChange={(e) => update({ pageSize: Number(e.target.value), page: 1 })}>
            {pageSizes.map((size) => (
              <option key={size} value={size}>
                {size}
              </option>
            ))}
          </select>
        </label>
      </div>
      <RefreshStamp query={list} />

      {report && <BulkReport results={report} onDismiss={() => setReport(null)} />}
      {resend.isError && <Notice kind="error">{describeResendError(resend.error)}</Notice>}

      {/* Çubuk hep yerinde durur: ilk seçimde ortaya çıkıp tabloyu aşağı kaydırırsa hızlı tıklayan yanlış satırı seçer. */}
      <div className="bulkbar">
        {selected.size === 0 ? (
          <span className="muted">{tr.invoices.nothingSelected}</span>
        ) : (
          <>
            <span>{tr.invoices.selectedCount(selected.size, maxSelection)}</span>
            {confirming ? (
              <>
                <strong>{tr.invoices.bulkConfirm(selected.size)}</strong>
                <button type="button" className="primary" disabled={resend.isPending} onClick={() => resend.mutate([...selected])}>
                  {resend.isPending ? tr.invoices.bulkSending : tr.common.yes}
                </button>
                <button type="button" disabled={resend.isPending} onClick={() => setConfirming(false)}>
                  {tr.common.cancel}
                </button>
              </>
            ) : (
              <>
                <button type="button" className="primary" onClick={() => setConfirming(true)}>
                  {tr.invoices.bulkResend}
                </button>
                <button type="button" onClick={clearSelection}>
                  {tr.invoices.clearSelection}
                </button>
              </>
            )}
          </>
        )}
      </div>
      {limitReached && <Notice kind="info">{tr.invoices.selectionLimit(maxSelection)}</Notice>}

      <QueryState query={list}>
        {(data) => (
          <>
            <InvoiceTable
              invoices={data.items}
              selected={selected}
              onToggle={(number) => choose(toggle(selected, number))}
              onSelectPage={(numbers, on) => (on ? choose(selectMany(selected, numbers)) : choose({ selected: deselectMany(selected, numbers), limitReached: false }))}
            />
            <div className="pager">
              <span>{tr.invoices.totalCount(data.totalCount)}</span>
              <button type="button" disabled={data.page <= 1} onClick={() => update({ page: data.page - 1 })}>
                {tr.invoices.previous}
              </button>
              <span>{tr.invoices.page(data.page, data.totalPages)}</span>
              <button type="button" disabled={data.page >= data.totalPages} onClick={() => update({ page: data.page + 1 })}>
                {tr.invoices.next}
              </button>
            </div>
          </>
        )}
      </QueryState>
    </>
  )
}

interface TableProps {
  invoices: Invoice[]
  selected: ReadonlySet<string>
  onToggle: (invoiceNumber: string) => void
  onSelectPage: (invoiceNumbers: string[], selectThem: boolean) => void
}

function InvoiceTable({ invoices, selected, onToggle, onSelectPage }: TableProps) {
  const failedOnPage = invoices.filter((i) => i.status === failedStatus).map((i) => i.invoiceNumber)
  const allFailedSelected = failedOnPage.length > 0 && failedOnPage.every((n) => selected.has(n))

  if (invoices.length === 0) return <p className="muted">{tr.invoices.noMatch}</p>

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>
              <input
                type="checkbox"
                aria-label={tr.invoices.selectAllFailed}
                title={tr.invoices.selectAllFailed}
                disabled={failedOnPage.length === 0}
                checked={allFailedSelected}
                onChange={(e) => onSelectPage(failedOnPage, e.target.checked)}
              />
            </th>
            <th>{tr.invoices.columns.invoiceNumber}</th>
            <th>{tr.invoices.columns.customerCode}</th>
            <th className="num">{tr.invoices.columns.amount}</th>
            <th>{tr.invoices.columns.status}</th>
            <th className="num">{tr.invoices.columns.attempts}</th>
            <th>{tr.invoices.columns.lastError}</th>
            <th>{tr.invoices.columns.updatedAt}</th>
            <th>{tr.invoices.columns.detail}</th>
          </tr>
        </thead>
        <tbody>
          {invoices.map((invoice) => {
            const canSelect = invoice.status === failedStatus
            return (
              <tr key={invoice.invoiceNumber} className={selected.has(invoice.invoiceNumber) ? 'row-selected' : ''}>
                <td>
                  {canSelect && (
                    <input
                      type="checkbox"
                      aria-label={`${invoice.invoiceNumber} ${tr.invoices.columns.select}`}
                      checked={selected.has(invoice.invoiceNumber)}
                      onChange={() => onToggle(invoice.invoiceNumber)}
                    />
                  )}
                </td>
                <td>{invoice.invoiceNumber}</td>
                <td>{invoice.customerCode}</td>
                <td className="num">{formatAmount(invoice.amount, invoice.currency)}</td>
                <td>
                  <StatusBadge status={invoice.status} />
                </td>
                <td className="num">{invoice.sendAttemptCount}</td>
                <td className="truncate" title={invoice.lastError ?? undefined}>
                  {invoice.lastError ?? emptyValue}
                </td>
                <td>{formatDateTime(invoice.updatedAt)}</td>
                <td>
                  <Link to={`/faturalar/${encodeURIComponent(invoice.invoiceNumber)}`}>{tr.invoices.detailLink}</Link>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function BulkReport({ results, onDismiss }: { results: ResendItem[]; onDismiss: () => void }) {
  const queued = results.filter((r) => r.result === 'queued').length
  const refused = results.filter((r) => r.result !== 'queued')

  return (
    <Notice kind={refused.length === 0 ? 'success' : 'info'}>
      <strong>{tr.invoices.bulkResultTitle}</strong>
      <p>{tr.invoices.bulkQueued(queued)}</p>
      {refused.length > 0 && (
        <>
          <p>{tr.invoices.bulkRefused(refused.length)}</p>
          <table className="inner">
            <thead>
              <tr>
                <th>{tr.invoices.columns.invoiceNumber}</th>
                <th>{tr.invoices.refusedReason}</th>
              </tr>
            </thead>
            <tbody>
              {refused.map((item) => (
                <tr key={item.invoiceNumber}>
                  <td>{item.invoiceNumber}</td>
                  <td>{describeResendRefusal(item)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
      <div className="actions">
        {/* Kuyruğa alınanlar Bekliyor durumundadır: bağlantı listeyi o durumla açar. */}
        {queued > 0 && (
          <Link to="/faturalar?durum=Bekliyor" onClick={onDismiss}>
            {tr.invoices.watchQueue}
          </Link>
        )}
        <button type="button" onClick={onDismiss}>
          {tr.invoices.dismiss}
        </button>
      </div>
    </Notice>
  )
}
