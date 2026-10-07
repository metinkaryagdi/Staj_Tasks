// Fatura Servisi'nin cevaplarının şekli (alan adları API'ninkiyle aynı).

export const invoiceStatuses = ['Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız'] as const
export type InvoiceStatus = (typeof invoiceStatuses)[number]

export const failedStatus: InvoiceStatus = 'Başarısız'

export interface Invoice {
  invoiceNumber: string
  customerCode: string
  amount: number
  currency: string
  invoiceDate: string
  status: InvoiceStatus
  erpReference: string | null
  rejectReason: string | null
  lastError: string | null
  sendAttemptCount: number
  createdAt: string
  updatedAt: string
}

export interface InvoiceList {
  items: Invoice[]
  page: number
  pageSize: number
  totalCount: number
  totalPages: number
}

export interface InvoiceSummary {
  counts: { status: InvoiceStatus; count: number }[]
  total: number
  stuckCount: number
  stuckAfterMinutes: number
}

export interface OutboxEntry {
  status: string
  attemptCount: number
  nextAttemptAt: string
  lastError: string | null
  createdAt: string
  processedAt: string | null
}

export interface InvoiceEvent {
  eventId: string
  eventType: string
  status: string
  ignoreReason: string | null
  deliveryCount: number
  occurredAt: string
  receivedAt: string
  processedAt: string | null
}

export interface Finding {
  id: number
  runId: number
  invoiceNumber: string
  findingType: string
  action: 'Düzeltildi' | 'Raporlandı'
  details: string
  createdAt: string
}

export interface InvoiceDetails {
  invoice: Invoice
  outbox: OutboxEntry | null
  events: InvoiceEvent[]
  findings: Finding[]
}

export interface ReconciliationRun {
  id: number
  startedAt: string
  finishedAt: string | null
  status: 'Çalışıyor' | 'Tamamlandı' | 'Başarısız'
  checkedCount: number
  fixedCount: number
  reportedCount: number
  error: string | null
}

export interface ReconciliationRunDetail {
  run: ReconciliationRun
  findings: Finding[]
}

export type ResendResult = 'queued' | 'not_found' | 'not_failed' | 'error'

export interface ResendItem {
  invoiceNumber: string
  result: ResendResult
  currentStatus: string | null
}

// Bir durum değil: Gönderildi ya da İşleme Alındı'da özetteki süreden uzun kalanlar (servis stuck=true ile süzer).
export const stuckFilter = 'Takılı'
export type StatusFilter = InvoiceStatus | typeof stuckFilter | ''

export interface InvoiceQuery {
  status: StatusFilter
  search: string
  page: number
  pageSize: number
}
