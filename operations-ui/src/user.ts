// Giriş yapan kullanıcı, token'daki adı ve realm rolleriyle (keycloak/fatura-realm.json).

export const viewerRole = 'fatura-izleyici'
export const operatorRole = 'fatura-operatoru'

export interface User {
  name: string
  // Verileri görebilir: izleyici ya da operatör.
  canRead: boolean
  // Müdahale edebilir (yeniden gönderme, takip, mutabakat başlatma): yalnızca operatör.
  canIntervene: boolean
}

// Token'ın içinden okunan alanlar.
export interface TokenClaims {
  preferred_username?: string
  realm_access?: { roles?: string[] }
}

export function userFrom(claims: TokenClaims): User {
  const roles = claims.realm_access?.roles ?? []
  return {
    name: claims.preferred_username ?? '',
    canRead: roles.includes(viewerRole) || roles.includes(operatorRole),
    canIntervene: roles.includes(operatorRole),
  }
}
