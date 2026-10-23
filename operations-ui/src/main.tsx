import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter } from 'react-router-dom'
import { App } from './App'
import { signIn } from './auth'
import { Notice } from './components/Notice'
import { refreshIntervalMs } from './config'
import { tr } from './tr'
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

const root = createRoot(document.getElementById('root')!)

// Giriş bitmeden ekran çizilmez: veri ancak token'la istenir.
root.render(
  <main>
    <p className="muted">{tr.auth.signingIn}</p>
  </main>,
)

void signIn().then((result) => {
  if (result === 'unreachable') {
    root.render(
      <main>
        <Notice kind="error">{tr.auth.keycloakUnreachable}</Notice>
      </main>,
    )
  } else if (result === 'signed-in') {
    root.render(
      <StrictMode>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </QueryClientProvider>
      </StrictMode>,
    )
  }
  // 'redirecting': tarayıcı giriş sayfasına gidiyor, "Giriş yapılıyor" kalır.
})
