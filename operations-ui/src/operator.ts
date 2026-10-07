import { useSyncExternalStore } from 'react'

// Ekranı kullanan kişinin adı: yeniden gönderme ve mutabakat başlatma bu adla kaydedilir (X-Operator-Name). Kimlik
// doğrulama değildir. Tarayıcıda saklanır, sayfa yenilenince yeniden sorulmaz; tarayıcı saklamaya izin vermiyorsa (gizli
// pencere vb.) ad yalnızca sayfa açık kaldıkça hatırlanır.

const storageKey = 'operasyon-ekrani.operator'
export const operatorHeaderName = 'X-Operator-Name'

// Fatura Servisi'nin kabul ettiği en uzun ad.
export const maxNameLength = 100

function readStored(): string | null {
  try {
    return normalizeName(localStorage.getItem(storageKey) ?? '')
  } catch {
    return null
  }
}

let current: string | null = readStored()
const listeners = new Set<() => void>()

// Boşlukları kırpar; boş, çok uzun ya da kontrol karakterli ad geçersizdir (null).
export function normalizeName(input: string): string | null {
  const name = input.trim()
  if (name.length === 0 || name.length > maxNameLength) return null
  if (/\p{Cc}/u.test(name)) return null
  return name
}

export function getOperatorName(): string | null {
  return current
}

export function setOperatorName(name: string) {
  current = name
  try {
    localStorage.setItem(storageKey, name)
  } catch {
    // Saklanamadı: ad bu sayfa açık kaldıkça kullanılır.
  }
  listeners.forEach((notify) => notify())
}

export function useOperatorName(): string | null {
  return useSyncExternalStore(
    (notify) => {
      listeners.add(notify)
      return () => listeners.delete(notify)
    },
    getOperatorName,
  )
}

// Tarayıcı başlıkta yalnızca Latin-1 gönderir ("ğ", "ı", "ş" gönderilemez): ad yüzde kodlanır, servis çözer.
export function operatorHeaders(): Record<string, string> {
  return current === null ? {} : { [operatorHeaderName]: encodeURIComponent(current) }
}
