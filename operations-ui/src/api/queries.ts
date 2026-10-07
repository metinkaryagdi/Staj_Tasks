import { keepPreviousData, queryOptions } from '@tanstack/react-query'
import { refreshIntervalMs, runningRefreshIntervalMs } from '../config'
import { getInvoiceDetails, getInvoices, getRunDetail, getRuns, getSummary } from './endpoints'
import type { InvoiceQuery } from './types'

// Her sorgu main.tsx'teki varsayılanla 10 saniyede bir kendiliğinden yenilenir; bu dosyada yalnızca farklı olanlar yazılı.

export const summaryQuery = () => queryOptions({ queryKey: ['summary'], queryFn: getSummary })

// Sayfa ya da süzgeç değişirken eski liste yenisi gelene kadar ekranda kalır.
export const invoicesQuery = (query: InvoiceQuery) =>
  queryOptions({ queryKey: ['invoices', query], queryFn: () => getInvoices(query), placeholderData: keepPreviousData })

export const detailsQuery = (invoiceNumber: string) =>
  queryOptions({ queryKey: ['invoice-details', invoiceNumber], queryFn: () => getInvoiceDetails(invoiceNumber) })

// Çalışan bir mutabakat varken sonucu çabuk görünsün diye daha sık yenilenir.
export const runsQuery = (page: number, pageSize: number) =>
  queryOptions({
    queryKey: ['runs', page, pageSize],
    queryFn: () => getRuns(page, pageSize),
    placeholderData: keepPreviousData,
    refetchInterval: (query) =>
      query.state.data?.items.some((run) => run.status === 'Çalışıyor') ? runningRefreshIntervalMs : refreshIntervalMs,
  })

export const runDetailQuery = (id: number) =>
  queryOptions({
    queryKey: ['run-detail', id],
    queryFn: () => getRunDetail(id),
    refetchInterval: (query) => (query.state.data?.run.status === 'Çalışıyor' ? runningRefreshIntervalMs : refreshIntervalMs),
  })
