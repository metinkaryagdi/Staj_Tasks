import { tr } from '../tr'

// Takılı faturada durumun yanında gösterilir; takılı olup olmadığına servis karar verir, burada yalnızca ne kadar
// süredir aynı durumda olduğu yazılır.
export function StuckBadge({ since }: { since: string }) {
  return (
    <span className="badge badge-stuck" title={tr.stuckBadge.hint}>
      {tr.stuckBadge.label(waited(since))}
    </span>
  )
}

export function waited(since: string, now: number = Date.now()): string {
  const minutes = Math.max(0, Math.floor((now - new Date(since).getTime()) / 60_000))
  if (minutes < 60) return tr.stuckBadge.minutes(minutes)
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return tr.stuckBadge.hours(hours)
  return tr.stuckBadge.days(Math.floor(hours / 24))
}
