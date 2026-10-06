import { describe, expect, it } from 'vitest'
import { deselectMany, maxSelection, selectMany, toggle } from './selection'

const numbers = (count: number) => Array.from({ length: count }, (_, i) => `FTR-${String(i + 1).padStart(6, '0')}`)

describe('seçim', () => {
  it('bir faturayı seçer ve yeniden dokununca bırakır', () => {
    const picked = toggle(new Set(), 'FTR-000001')
    expect([...picked.selected]).toEqual(['FTR-000001'])
    expect([...toggle(picked.selected, 'FTR-000001').selected]).toEqual([])
  })

  it('yüzüncü faturaya kadar seçer, yüz birinciyi seçmez ve bunu bildirir', () => {
    const full = selectMany(new Set(), numbers(maxSelection))
    expect(full.selected.size).toBe(100)
    expect(full.limitReached).toBe(false)

    const over = toggle(full.selected, 'FTR-000101')
    expect(over.selected.size).toBe(100)
    expect(over.selected.has('FTR-000101')).toBe(false)
    expect(over.limitReached).toBe(true)
  })

  it('sınırda seçili bir faturayı yine bırakabilir', () => {
    const full = selectMany(new Set(), numbers(maxSelection))
    expect(toggle(full.selected, 'FTR-000001').selected.size).toBe(99)
  })

  it('toplu seçimde sığanı seçer, sığmayanı bırakır', () => {
    const start = selectMany(new Set(), numbers(95)).selected
    const result = selectMany(start, numbers(110))
    expect(result.selected.size).toBe(100)
    expect(result.limitReached).toBe(true)
  })

  it('zaten seçili olanları yeniden saymaz', () => {
    const start = selectMany(new Set(), numbers(100)).selected
    const result = selectMany(start, numbers(100))
    expect(result.limitReached).toBe(false)
  })

  it('sayfadaki seçimleri kaldırır, diğer sayfalarınkine dokunmaz', () => {
    const start = selectMany(new Set(), numbers(30)).selected
    expect(deselectMany(start, numbers(10)).size).toBe(20)
  })
})
