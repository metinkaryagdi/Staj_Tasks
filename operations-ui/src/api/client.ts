import { accessToken } from '../auth'
import { apiUrl, requestTimeoutMs } from '../config'

// unreachable: cevap alınamadı (servis kapalı, ağ yok, zaman aşımı ya da tarayıcı isteği engelledi)
// server:      servis 5xx verdi ya da anlaşılmaz bir cevap döndü
// rejected:    servis isteği anladı ama reddetti (4xx); code alanı nedenini söyler
// keycloak:    token yenilenemedi (Keycloak'a ulaşılamadı); istek Fatura Servisi'ne hiç gönderilmedi
export type ApiErrorKind = 'unreachable' | 'server' | 'rejected' | 'keycloak'

export class ApiError extends Error {
  constructor(
    readonly kind: ApiErrorKind,
    readonly status: number | null,
    readonly code: string | null = null,
    readonly currentStatus: string | null = null,
  ) {
    super(`${kind} ${status ?? ''} ${code ?? ''}`.trim())
  }
}

interface Problem {
  code?: string
  currentStatus?: string
}

async function readProblem(response: Response): Promise<Problem> {
  try {
    return (await response.json()) as Problem
  } catch {
    return {}
  }
}

export async function request<T>(path: string, init?: RequestInit): Promise<T> {
  // Her istek giriş yapan kullanıcının token'ıyla gider; servis rolü token'dan okur.
  let token: string
  try {
    token = await accessToken()
  } catch {
    throw new ApiError('keycloak', null)
  }
  const headers = new Headers(init?.headers)
  headers.set('Authorization', `Bearer ${token}`)

  let response: Response
  try {
    response = await fetch(`${apiUrl}${path}`, { ...init, headers, signal: AbortSignal.timeout(requestTimeoutMs) })
  } catch {
    throw new ApiError('unreachable', null)
  }

  if (response.ok) {
    try {
      return (await response.json()) as T
    } catch {
      throw new ApiError('server', response.status)
    }
  }

  const problem = await readProblem(response)
  const kind: ApiErrorKind = response.status >= 500 ? 'server' : 'rejected'
  throw new ApiError(kind, response.status, problem.code ?? null, problem.currentStatus ?? null)
}

// Ekrandan yapılan her POST bir müdahaledir (yeniden gönderme, mutabakat başlatma); kimin yaptığını servis token'dan okur.
export function postJson<T>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, {
    method: 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}
