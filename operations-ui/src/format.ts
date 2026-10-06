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

export function formatAmount(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat('tr-TR', { style: 'currency', currency }).format(amount)
  } catch {
    return `${amount.toLocaleString('tr-TR')} ${currency}`
  }
}
