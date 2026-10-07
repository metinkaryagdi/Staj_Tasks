import { NavLink, Outlet } from 'react-router-dom'
import { useOperatorName } from '../operator'
import { tr } from '../tr'
import { ErrorBoundary } from './ErrorBoundary'
import { OperatorGate } from './OperatorGate'

export function Layout() {
  const operator = useOperatorName()
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
          {operator !== null && <span className="operator">{tr.operator.current(operator)}</span>}
        </div>
      </header>
      <main>
        <ErrorBoundary>
          <OperatorGate>
            <Outlet />
          </OperatorGate>
        </ErrorBoundary>
      </main>
    </>
  )
}
