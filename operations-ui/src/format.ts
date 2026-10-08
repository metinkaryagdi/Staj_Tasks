import { tr } from './tr'

const dateTime = new Intl.DateTimeFormat('tr-TR', { dateStyle: 'short', timeStyle: 'medium' })
const date = new Intl.DateTimeFormat('tr-TR', { dateStyle: 'medium', timeZone: 'UTC' })

export const emptyValue = '—'

export function formatDateTime(value: string | null | undefined): string {
  return value ? dateTime.format(new Date(value)) : emptyValue
}

// fatura tarihi "2026-09-30" biçiminde gelir; saat dilimi kaydırmasın diye UTC okunur.
export function formatDate(value: string | null | undefined): string {
  return value ? date.format(new Date(`${value}T00:00:00Z`)) : emptyValue
}

// Kuyruktaki bekleme: bir dakikadan kısası saniye, bir saatten kısası dakika ve saniye, uzunu saat ve dakika.
export function formatWait(seconds: number | null): string {
  if (seconds === null) return emptyValue
  if (seconds < 60) return tr.summary.seconds(seconds)
  if (seconds < 3600) return tr.summary.minutesSeconds(Math.floor(seconds / 60), seconds % 60)
  return tr.summary.hoursMinutes(Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60))
}

export function formatAmount(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat('tr-TR', { style: 'currency', currency }).format(amount)
  } catch {
    return `${amount.toLocaleString('tr-TR')} ${currency}`
  }
}
