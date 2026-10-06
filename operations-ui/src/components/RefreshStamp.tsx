import type { UseQueryResult } from '@tanstack/react-query'
import { formatDateTime } from '../format'
import { tr } from '../tr'

// "Son yenileme" zamanı: yenilemenin gerçekten çalıştığı (ya da durduğu) görünsün.
export function RefreshStamp({ query }: { query: UseQueryResult<unknown> }) {
  return (
    <p className="muted small">
      {tr.common.refreshNote}
      {query.dataUpdatedAt > 0 && (
        <>
          {' '}
          {tr.common.lastRefresh}: {formatDateTime(new Date(query.dataUpdatedAt).toISOString())}
        </>
      )}
    </p>
  )
}
