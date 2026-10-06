import { Link, Route, Routes } from 'react-router-dom'
import { Layout } from './components/Layout'
import { InvoiceDetailPage } from './pages/InvoiceDetailPage'
import { InvoiceListPage } from './pages/InvoiceListPage'
import { ReconciliationPage } from './pages/ReconciliationPage'
import { SummaryPage } from './pages/SummaryPage'
import { tr } from './tr'

export function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<SummaryPage />} />
        <Route path="faturalar" element={<InvoiceListPage />} />
        <Route path="faturalar/:invoiceNumber" element={<InvoiceDetailPage />} />
        <Route path="mutabakat" element={<ReconciliationPage />} />
        <Route
          path="*"
          element={
            <>
              <h1>{tr.common.notFoundTitle}</h1>
              <Link to="/">{tr.common.backToSummary}</Link>
            </>
          }
        />
      </Route>
    </Routes>
  )
}
