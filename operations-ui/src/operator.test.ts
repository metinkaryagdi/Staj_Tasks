import { describe, expect, it } from 'vitest'
import { normalizeName, operatorHeaders, setOperatorName } from './operator'

describe('operatör adı', () => {
  it('boşlukları kırpar; boş, çok uzun ya da kontrol karakterli adı kabul etmez', () => {
    expect(normalizeName('  Ayşe Yılmaz ')).toBe('Ayşe Yılmaz')
    expect(normalizeName('   ')).toBeNull()
    expect(normalizeName('a'.repeat(101))).toBeNull()
    expect(normalizeName('a'.repeat(100))).toHaveLength(100)
    expect(normalizeName('Ayşe\nYılmaz')).toBeNull()
  })

  it('Türkçe karakterli adı başlıkta yüzde kodlu gönderir', () => {
    setOperatorName('Ayşe Yılmaz')
    expect(operatorHeaders()).toEqual({ 'X-Operator-Name': 'Ay%C5%9Fe%20Y%C4%B1lmaz' })
  })
})
