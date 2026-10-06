// Toplu yeniden gönderme için fatura seçimi. Fatura Servisi tek istekte en fazla bu kadar numara kabul eder.
export const maxSelection = 100

export interface SelectionChange {
  selected: Set<string>
  // İstenen seçimlerin bir kısmı sınır yüzünden yapılamadı.
  limitReached: boolean
}

export function toggle(selected: ReadonlySet<string>, invoiceNumber: string): SelectionChange {
  const next = new Set(selected)
  if (next.delete(invoiceNumber)) return { selected: next, limitReached: false }
  if (next.size >= maxSelection) return { selected: next, limitReached: true }
  next.add(invoiceNumber)
  return { selected: next, limitReached: false }
}

// Sınıra kadar ekler; sığmayanlar seçilmez.
export function selectMany(selected: ReadonlySet<string>, invoiceNumbers: readonly string[]): SelectionChange {
  const next = new Set(selected)
  let limitReached = false
  for (const number of invoiceNumbers) {
    if (next.has(number)) continue
    if (next.size >= maxSelection) {
      limitReached = true
      break
    }
    next.add(number)
  }
  return { selected: next, limitReached }
}

export function deselectMany(selected: ReadonlySet<string>, invoiceNumbers: readonly string[]): Set<string> {
  const next = new Set(selected)
  for (const number of invoiceNumbers) next.delete(number)
  return next
}
