import { describe, expect, it } from 'vitest'
import { cancelAction } from './cancellation'

describe('iptal düğmesi', () => {
  it.each(['Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Başarısız'])('%s fatura iptal edilebilir', (status) => {
    expect(cancelAction(status, null)).toBe('cancel')
  })

  it.each(['Reddedildi', 'İptal Edildi'])('%s fatura iptal edilemez', (status) => {
    expect(cancelAction(status, null)).toBe('closed')
    expect(cancelAction(status, 'Başarısız')).toBe('closed')
  })

  it('başarısız iptal yeniden denenebilir', () => {
    expect(cancelAction('Onaylandı', 'Başarısız')).toBe('retry')
  })

  it.each(['Bekliyor', 'Tamamlandı'])('iptal satırı %s iken düğme kapalıdır', (status) => {
    expect(cancelAction('Onaylandı', status)).toBe('closed')
  })
})
