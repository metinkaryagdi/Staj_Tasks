import { postJson, request } from './client'
import {
  stuckFilter,
  type Invoice,
  type InvoiceDetails,
  type InvoiceFollowUp,
  type InvoiceList,
  type InvoiceQuery,
  type InvoiceSummary,
  type ReconciliationRun,
  type ReconciliationRunDetail,
  type ReconciliationRunList,
  type ResendItem,
} from './types'

const invoices = '/api/v1/invoices'
const runs = '/api/v1/reconciliation-runs'

export function getSummary() {
  return request<InvoiceSummary>(`${invoices}/summary`)
}

export function getInvoices(query: InvoiceQuery) {
  const params = new URLSearchParams({ page: String(query.page), pageSize: String(query.pageSize) })
  if (query.status === stuckFilter) params.set('stuck', 'true')
  else if (query.status) params.set('status', query.status)
  if (query.search) params.set('search', query.search)
  return request<InvoiceList>(`${invoices}?${params}`)
}

export function getInvoiceDetails(invoiceNumber: string) {
  return request<InvoiceDetails>(`${invoices}/${encodeURIComponent(invoiceNumber)}/details`)
}

export function resendInvoice(invoiceNumber: string) {
  return postJson<Invoice>(`${invoices}/${encodeURIComponent(invoiceNumber)}/resend`)
}

export function openInvoiceFollowUp(invoiceNumber: string, note: string) {
  return postJson<InvoiceFollowUp>(`${invoices}/${encodeURIComponent(invoiceNumber)}/follow-up`, { note })
}

export function closeInvoiceFollowUp(invoiceNumber: string) {
  return postJson<InvoiceFollowUp>(`${invoices}/${encodeURIComponent(invoiceNumber)}/follow-up/close`)
}

export async function resendInvoices(invoiceNumbers: string[]) {
  const response = await postJson<{ results: ResendItem[] }>(`${invoices}/resend`, { invoiceNumbers })
  return response.results
}

export function getRuns(page: number, pageSize: number) {
  return request<ReconciliationRunList>(`${runs}?${new URLSearchParams({ page: String(page), pageSize: String(pageSize) })}`)
}

export function getRunDetail(id: number) {
  return request<ReconciliationRunDetail>(`${runs}/${id}`)
}

export function startRun() {
  return postJson<ReconciliationRun>(runs)
}
