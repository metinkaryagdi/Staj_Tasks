import { useQueryClient } from '@tanstack/react-query'
import { NavLink, Outlet } from 'react-router-dom'
import { currentUser, signOut } from '../auth'
import { tr } from '../tr'
import { ErrorBoundary } from './ErrorBoundary'
import { IdleTimeout } from './IdleTimeout'
import { Notice } from './Notice'

export function Layout() {
  const user = currentUser()
  const queryClient = useQueryClient()
  return (
    <>
      <header className="topbar">
        <div className="topbar-inner">
          <strong className="brand">{tr.appTitle}</strong>
          {user.canRead && (
            <nav>
              <NavLink to="/" end>
                {tr.nav.summary}
              </NavLink>
              <NavLink to="/faturalar">{tr.nav.invoices}</NavLink>
              <NavLink to="/mutabakat">{tr.nav.reconciliation}</NavLink>
            </nav>
          )}
          <span className="user">
            {tr.auth.user(user.name)}{' '}
            <button type="button" className="link sign-out" onClick={() => signOut(() => queryClient.clear())}>
              {tr.auth.signOut}
            </button>
          </span>
        </div>
      </header>
      <main>
        <IdleTimeout />
        <ErrorBoundary>
          {user.canRead ? (
            <Outlet />
          ) : (
            // Rolü olmayan kullanıcıya hiçbir sayfa açılmaz; servis de onun isteklerini 403 ile reddeder.
            <>
              <h1>{tr.auth.noAccessTitle}</h1>
              <Notice kind="error">{tr.auth.noAccess(user.name)}</Notice>
            </>
          )}
        </ErrorBoundary>
      </main>
    </>
  )
}
