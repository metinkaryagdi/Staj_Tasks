import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { signOut } from '../auth'
import { idleTimeoutMinutes, idleWarningMs } from '../config'
import { tr } from '../tr'
import { Notice } from './Notice'

const timeoutMs = idleTimeoutMinutes * 60_000

// Kullanıcı idleTimeoutMinutes boyunca hiçbir işlem yapmazsa oturumu kapatır (Çıkış ile aynı: veriler silinir, Keycloak'taki
// oturum kapanır, giriş sayfası açılır); süre dolmadan 1 dakika önce uyarı ve "Oturumu uzat" gösterir. Yalnızca kullanıcının
// tıklaması, tuşa basması ve kaydırması işlem sayılır: ekranın 10 saniyelik yenilemeleri bu olayları tetiklemez. Ekranın
// yenilemeleri Keycloak'ın oturumunu canlı tutar; bu yüzden süreyi ekran kendisi sayar.
export function IdleTimeout() {
  const lastActivity = useRef(Date.now())
  const queryClient = useQueryClient()
  // null: uyarı yok; sayı: uyarı açık, oturumun kapanmasına kalan saniye.
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null)

  useEffect(() => {
    const markActive = () => {
      lastActivity.current = Date.now()
    }
    const events = ['pointerdown', 'keydown', 'wheel']
    events.forEach((name) => window.addEventListener(name, markActive))
    return () => events.forEach((name) => window.removeEventListener(name, markActive))
  }, [])

  // Tek bir 15 dakikalık zamanlayıcı yerine her saniye gerçek saate bakılır: tarayıcı arka plandaki sekmenin
  // zamanlayıcılarını yavaşlatır, bilgisayar uykudayken durdurur; geçen süre yine doğru hesaplanır.
  useEffect(() => {
    const timer = window.setInterval(() => {
      const left = timeoutMs - (Date.now() - lastActivity.current)
      if (left <= 0) {
        window.clearInterval(timer)
        signOut(() => queryClient.clear())
      } else {
        setSecondsLeft(left <= idleWarningMs ? Math.ceil(left / 1000) : null)
      }
    }, 1000)
    return () => window.clearInterval(timer)
  }, [queryClient])

  const extend = () => {
    lastActivity.current = Date.now()
    setSecondsLeft(null)
  }

  if (secondsLeft === null) return null
  return (
    <Notice kind="info">
      <p>{tr.auth.idleWarning(secondsLeft)}</p>
      <div className="actions">
        <button type="button" className="primary" onClick={extend}>
          {tr.auth.extendSession}
        </button>
      </div>
    </Notice>
  )
}
