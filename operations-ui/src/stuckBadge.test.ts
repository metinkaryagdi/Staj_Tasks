import { describe, expect, it } from 'vitest'
import { waited } from './components/StuckBadge'

describe('takılı rozetindeki süre', () => {
  const now = Date.parse('2026-10-07T12:00:00Z')

  it('bir saatten kısa beklemeyi dakika, iki günden kısayı saat, uzununu gün olarak yazar', () => {
    expect(waited('2026-10-07T11:57:30Z', now)).toBe('2 dk')
    expect(waited('2026-10-06T20:00:00Z', now)).toBe('16 sa')
    expect(waited('2026-10-04T12:00:00Z', now)).toBe('3 gün')
  })
})
