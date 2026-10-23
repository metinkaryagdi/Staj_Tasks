import { describe, expect, it } from 'vitest'
import { operatorRole, userFrom, viewerRole } from './user'

describe('token\'dan kullanıcı', () => {
  it('operatör okur ve müdahale eder', () => {
    expect(userFrom({ preferred_username: 'operator', realm_access: { roles: [operatorRole] } }))
      .toEqual({ name: 'operator', canRead: true, canIntervene: true })
  })

  it('izleyici okur, müdahale etmez', () => {
    expect(userFrom({ preferred_username: 'izleyici', realm_access: { roles: [viewerRole] } }))
      .toEqual({ name: 'izleyici', canRead: true, canIntervene: false })
  })

  it('rolü olmayan kullanıcı ne okur ne müdahale eder', () => {
    expect(userFrom({ preferred_username: 'rolsuz', realm_access: { roles: [] } }))
      .toEqual({ name: 'rolsuz', canRead: false, canIntervene: false })
    expect(userFrom({ preferred_username: 'rolsuz' })).toEqual({ name: 'rolsuz', canRead: false, canIntervene: false })
  })
})
