import { NavLink, Outlet } from 'react-router-dom'
import { tr } from '../tr'
import { ErrorBoundary } from './ErrorBoundary'

export function Layout() {
  return (
    <>
      <header className="topbar">
        <div className="topbar-inner">
          <strong className="brand">{tr.appTitle}</strong>
          <nav>
            <NavLink to="/" end>
              {tr.nav.summary}
            </NavLink>
            <NavLink to="/faturalar">{tr.nav.invoices}</NavLink>
            <NavLink to="/mutabakat">{tr.nav.reconciliation}</NavLink>
          </nav>
        </div>
      </header>
      <main>
        <ErrorBoundary>
          <Outlet />
        </ErrorBoundary>
      </main>
    </>
  )
}
