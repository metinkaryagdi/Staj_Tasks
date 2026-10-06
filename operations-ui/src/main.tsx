import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter } from 'react-router-dom'
import { App } from './App'
import { refreshIntervalMs } from './config'
import './styles.css'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Her sayfa kendiliğinden yenilenir; servise ulaşılamazsa yenileme sürer, servis dönünce sayfa toparlanır.
      refetchInterval: refreshIntervalMs,
      // Tek bir ağ hatası hemen hata göstermesin, ama servis kapalıyken de uzun beklenmesin.
      retry: 1,
      retryDelay: 1_000,
    },
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
)
