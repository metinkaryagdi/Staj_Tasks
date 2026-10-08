import { describe, expect, it } from 'vitest'
import { formatWait } from './format'

describe('kuyruktaki bekleme süresi', () => {
  it('bir dakikadan kısayı saniye, bir saatten kısayı dakika ve saniye, uzununu saat ve dakika olarak yazar', () => {
    expect(formatWait(0)).toBe('0 sn')
    expect(formatWait(59)).toBe('59 sn')
    expect(formatWait(60)).toBe('1 dk 0 sn')
    expect(formatWait(754)).toBe('12 dk 34 sn')
    expect(formatWait(3600)).toBe('1 sa 0 dk')
    expect(formatWait(7_385)).toBe('2 sa 3 dk')
  })

  it('kuyruk boşken boş değer işaretini yazar', () => {
    expect(formatWait(null)).toBe('—')
  })
})
