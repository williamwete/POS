import { beforeEach, describe, expect, it } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useSessionStore } from './session'
import { configureServices } from '@/services'
import type { MeResponse } from '@/types/api'

const JKT = '00000000-0000-4000-8000-000000000101'
const BDG = '00000000-0000-4000-8000-000000000102'

function me(partial: Partial<MeResponse> = {}): MeResponse {
  return {
    user: { id: 'u1', username: 'cashier.jkt', email: 'c@demo.local', displayName: 'Dewi' },
    organization: { id: 'org', code: 'DEMO', name: 'Demo', timezone: 'Asia/Jakarta', currency: 'IDR' },
    roles: [{ roleId: 'r1', roleCode: 'CASHIER', roleName: 'Cashier', outletId: JKT, outletCode: 'JKT01' }],
    organizationPermissions: [],
    outlets: [
      { id: JKT, code: 'JKT01', name: 'Jakarta', timezone: 'Asia/Jakarta', active: true, businessDate: '2026-10-02', permissions: ['sale.create'] },
    ],
    ...partial,
  }
}

describe('session store permission checks (UX only; backend re-validates)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    sessionStorage.clear()
    configureServices({
      auth: { signIn: async () => {}, getAccessToken: async () => null, signOut: async () => {} },
    })
  })

  it('denies everything when not logged in', () => {
    const s = useSessionStore()
    expect(s.can('sale.create', 'any')).toBe(false)
  })

  it('evaluates permissions per outlet scope', () => {
    const s = useSessionStore()
    s.me = me()
    s.selectContext(JKT, { id: 't1', code: 'POS-JKT-01', name: 'Kasir 1' })
    expect(s.can('sale.create')).toBe(true)
    expect(s.can('sale.create', JKT)).toBe(true)
    expect(s.can('sale.create', BDG)).toBe(false)
    expect(s.can('sale.create', 'org')).toBe(false)
    expect(s.can('sale.void')).toBe(false)
    expect(s.can('sale.create', 'any')).toBe(true)
  })

  it('org-wide permissions satisfy the "any" scope', () => {
    const s = useSessionStore()
    s.me = me({ organizationPermissions: ['user.manage'] })
    expect(s.can('user.manage', 'org')).toBe(true)
    expect(s.can('user.manage', 'any')).toBe(true)
  })

  it('refuses to select an outlet the user cannot access', () => {
    const s = useSessionStore()
    s.me = me()
    expect(() => s.selectContext(BDG, null)).toThrow()
    expect(s.outletId).toBeNull()
  })

  it('persists selected context in sessionStorage only', () => {
    const s = useSessionStore()
    s.me = me()
    s.selectContext(JKT, { id: 't1', code: 'POS-JKT-01', name: 'Kasir 1' })
    expect(sessionStorage.getItem('pos.context')).toContain('POS-JKT-01')
    s.clearContext()
    expect(sessionStorage.getItem('pos.context')).toBeNull()
  })
})
