import { describe, expect, it } from 'vitest'
import { ApiError } from './api/client'
import { describeError, describeResendError, describeResendRefusal, describeStartRunError } from './tr'

describe('hata mesajları', () => {
  it('servise ulaşılamayınca anlaşılır bir mesaj verir ve ham hata göstermez', () => {
    const message = describeError(new ApiError('unreachable', null))
    expect(message).toContain("Fatura Servisi'ne ulaşılamıyor")
    expect(message).not.toContain('unreachable')
  })

  it('başkası yeniden göndermişse fatura durumunu söyler', () => {
    const message = describeResendError(new ApiError('rejected', 409, 'invoice_not_failed', 'Bekliyor'))
    expect(message).toContain('"Bekliyor"')
    expect(message).toContain('Başka biri')
  })

  it('mutabakat zaten çalışıyorsa bunu söyler', () => {
    const message = describeStartRunError(new ApiError('rejected', 409, 'reconciliation_running'))
    expect(message).toContain('zaten çalışıyor')
  })

  it('cevap alınamayan müdahalede işlemin belirsiz olduğunu saklamaz', () => {
    expect(describeResendError(new ApiError('unreachable', null))).toContain('belli değil')
    expect(describeStartRunError(new ApiError('unreachable', null))).toContain('belli değil')
  })

  it('toplu gönderimde reddedilen her fatura için nedenini yazar', () => {
    expect(describeResendRefusal({ invoiceNumber: 'A', result: 'not_found', currentStatus: null })).toContain('bulunamadı')
    expect(describeResendRefusal({ invoiceNumber: 'A', result: 'not_failed', currentStatus: 'Onaylandı' })).toContain('"Onaylandı"')
    expect(describeResendRefusal({ invoiceNumber: 'A', result: 'error', currentStatus: null })).toContain('hata verdi')
  })
})
