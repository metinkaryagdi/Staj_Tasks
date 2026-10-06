import type { ReactNode } from 'react'
import type { UseQueryResult } from '@tanstack/react-query'
import { describeError, tr } from '../tr'
import { Notice } from './Notice'

interface Props<T> {
  query: UseQueryResult<T>
  children: (data: T) => ReactNode
}

// Bir sorgunun üç durumunu tek yerde gösterir. Veri bir kez geldiyse sonraki bir hata ekranı boşaltmaz: son bilinen veri
// bir uyarıyla birlikte kalır, servis geri gelince uyarı kendiliğinden kalkar.
export function QueryState<T>({ query, children }: Props<T>) {
  if (query.data !== undefined) {
    return (
      <>
        {query.isError && (
          <Notice kind="error">
            {describeError(query.error)} {tr.common.staleNote}
          </Notice>
        )}
        {children(query.data)}
      </>
    )
  }

  if (query.isError) return <Notice kind="error">{describeError(query.error)}</Notice>
  return <p className="muted">{tr.common.loading}</p>
}
