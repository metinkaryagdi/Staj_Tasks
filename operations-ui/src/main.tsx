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
      // Ekran bir başka pencerede açık bırakılabilir; sekme arka planda da olsa yenileme durmaz.
      refetchIntervalInBackground: true,
      // Yeniden deneme işini zaten 10 saniyelik yenileme görür. Kütüphanenin kendi denemesi kapalı: gizli bir sekmede
      // beklemeye alındığı için hata mesajı hiç görünmeyip sayfa "Yükleniyor" da kalabiliyordu.
      retry: false,
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
