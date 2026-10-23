import Keycloak from 'keycloak-js'
import { keycloakClientId, keycloakRealm, keycloakUrl, requestTimeoutMs } from './config'
import { userFrom, type User } from './user'

// Giriş Keycloak'ın kendi sayfasında yapılır (Authorization Code + PKCE). Token yalnızca bu nesnenin içinde, bellekte
// durur: localStorage'a ya da sessionStorage'a yazılmaz; sayfa yenilenince Keycloak'tan yeniden alınır (Keycloak'ta oturum
// açıksa şifre sorulmaz).
const keycloak = new Keycloak({ url: keycloakUrl, realm: keycloakRealm, clientId: keycloakClientId })

let user: User | null = null

// signed-in:   giriş yapıldı, ekran açılabilir
// redirecting: giriş yapılmamış; tarayıcı Keycloak'ın giriş sayfasına gidiyor
// unreachable: Keycloak'a ulaşılamadı
export type SignInResult = 'signed-in' | 'redirecting' | 'unreachable'

// Önce Keycloak'a ulaşılabildiği denetlenir: ulaşılamıyorken giriş sayfasına yönlendirilseydi kullanıcı ekranın mesajı
// yerine tarayıcının hata sayfasını görürdü.
export async function signIn(): Promise<SignInResult> {
  try {
    const discovery = await fetch(`${keycloakUrl}/realms/${keycloakRealm}/.well-known/openid-configuration`, {
      signal: AbortSignal.timeout(requestTimeoutMs),
    })
    if (!discovery.ok) return 'unreachable'
    // Keycloak'ın oturum iframe'i kapalı: üçüncü taraf çerezlerini engelleyen tarayıcılarda çalışmaz; oturum token
    // yenilenirken denetlenir.
    const authenticated = await keycloak.init({ onLoad: 'login-required', pkceMethod: 'S256', checkLoginIframe: false })
    if (!authenticated) return 'redirecting'
  } catch {
    return 'unreachable'
  }
  user = userFrom(keycloak.tokenParsed ?? {})
  return 'signed-in'
}

// signIn 'signed-in' döndükten sonra çağrılır.
export function currentUser(): User {
  if (user === null) throw new Error('Giriş yapılmadan kullanıcı okunamaz.')
  return user
}

// Her istekten önce: token'ın 30 saniyeden az ömrü kaldıysa Keycloak'tan yenisi alınır, kullanıcı çalışırken oturum
// kesilmez. Keycloak'a ulaşılamazsa hata fırlatır. Keycloak oturumu bitmiş sayarsa (yenileme reddedilirse) kütüphane
// giriş sayfasına yönlendirir.
export async function accessToken(): Promise<string> {
  await keycloak.updateToken(30)
  return keycloak.token!
}

// Önce ekranın bellekteki verileri silinir, sonra Keycloak'taki oturum kapatılır ve ekrana dönülür; dönüşte oturum
// olmadığı için giriş sayfası açılır.
export function signOut(clearData: () => void) {
  clearData()
  void keycloak.logout({ redirectUri: `${window.location.origin}/` })
}
