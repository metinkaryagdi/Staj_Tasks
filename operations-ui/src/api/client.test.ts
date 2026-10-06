import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, request } from './client'

function respond(status: number, body: unknown) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify(body), { status })))
}

async function failure(): Promise<ApiError> {
  try {
    await request('/x')
  } catch (error) {
    return error as ApiError
  }
  throw new Error('istek başarılı oldu')
}

afterEach(() => vi.unstubAllGlobals())

describe('API istemcisi', () => {
  it('başarılı cevabı çözümler', async () => {
    respond(200, { total: 3 })
    expect(await request('/x')).toEqual({ total: 3 })
  })

  it('servise ulaşılamazsa unreachable hatası verir', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')))
    const error = await failure()
    expect(error.kind).toBe('unreachable')
    expect(error.status).toBeNull()
  })

  it('5xx cevabını server hatası sayar', async () => {
    respond(503, {})
    const error = await failure()
    expect(error.kind).toBe('server')
    expect(error.status).toBe(503)
  })

  it('409 cevabının kodunu ve fatura durumunu taşır', async () => {
    respond(409, { code: 'invoice_not_failed', currentStatus: 'Bekliyor' })
    const error = await failure()
    expect(error.kind).toBe('rejected')
    expect(error.code).toBe('invoice_not_failed')
    expect(error.currentStatus).toBe('Bekliyor')
  })

  it('gövdesi JSON olmayan hata cevabında da çökmez', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('<html>', { status: 502 })))
    const error = await failure()
    expect(error.kind).toBe('server')
  })

  it('gövdesi JSON olmayan başarılı cevabı server hatası sayar', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('<html>', { status: 200 })))
    const error = await failure()
    expect(error.kind).toBe('server')
  })
})
