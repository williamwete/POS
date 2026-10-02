import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api, auth } from '@/services'
import type { MeResponse, OutletAccess, Terminal } from '@/types/api'

const CONTEXT_KEY = 'pos.context'

interface StoredContext {
  outletId: string | null
  terminal: Pick<Terminal, 'id' | 'code' | 'name'> | null
}

/**
 * Sesi login + konteks kerja (outlet & terminal).
 *
 * PENTING (§5): pengecekan permission di sini hanya untuk menyembunyikan menu/aksi.
 * Backend dan RLS selalu memvalidasi ulang setiap request.
 */
export const useSessionStore = defineStore('session', () => {
  const me = ref<MeResponse | null>(null)
  const outletId = ref<string | null>(null)
  const terminal = ref<StoredContext['terminal']>(null)

  const isAuthenticated = computed(() => me.value !== null)
  const outlets = computed<OutletAccess[]>(() => me.value?.outlets ?? [])
  const currentOutlet = computed(() => outlets.value.find((o) => o.id === outletId.value) ?? null)
  const roleSummary = computed(() =>
    (me.value?.roles ?? []).map((r) => (r.outletCode ? `${r.roleName} (${r.outletCode})` : r.roleName)),
  )

  /**
   * scope:
   *  - 'org'     : permission level organisasi (role org-wide)
   *  - 'current' : permission di outlet yang sedang dipilih
   *  - 'any'     : permission di organisasi atau di outlet mana pun
   *  - string    : permission di outlet tertentu (id)
   */
  function can(permission: string, scope: 'org' | 'current' | 'any' | string = 'current'): boolean {
    const m = me.value
    if (!m) return false
    const orgHas = m.organizationPermissions.includes(permission)
    if (scope === 'org') return orgHas
    if (scope === 'any') return orgHas || m.outlets.some((o) => o.permissions.includes(permission))
    const target = scope === 'current' ? outletId.value : scope
    const outlet = m.outlets.find((o) => o.id === target)
    return outlet ? outlet.permissions.includes(permission) : false
  }

  function persistContext() {
    const value: StoredContext = { outletId: outletId.value, terminal: terminal.value }
    sessionStorage.setItem(CONTEXT_KEY, JSON.stringify(value))
  }

  function restoreContext() {
    try {
      const raw = sessionStorage.getItem(CONTEXT_KEY)
      if (!raw) return
      const ctx = JSON.parse(raw) as StoredContext
      // Konteks hanya dipulihkan jika outlet masih dapat diakses user ini.
      if (ctx.outletId && outlets.value.some((o) => o.id === ctx.outletId)) {
        outletId.value = ctx.outletId
        terminal.value = ctx.terminal
      }
    } catch {
      sessionStorage.removeItem(CONTEXT_KEY)
    }
  }

  function selectContext(newOutletId: string, newTerminal: StoredContext['terminal']) {
    if (!outlets.value.some((o) => o.id === newOutletId)) {
      throw new Error('Outlet tidak dapat diakses')
    }
    outletId.value = newOutletId
    terminal.value = newTerminal
    persistContext()
  }

  function clearContext() {
    outletId.value = null
    terminal.value = null
    sessionStorage.removeItem(CONTEXT_KEY)
  }

  async function login(email: string, password: string) {
    await auth().signIn(email.trim().toLowerCase(), password)
    try {
      const res = await api().post<MeResponse>('/api/auth/session', {}, { skipAuthRedirect: true })
      me.value = res.data
    } catch (e) {
      await auth().signOut()
      throw e
    }
    clearContext()
    // Satu outlet saja: pilih otomatis.
    if (outlets.value.length === 1) outletId.value = outlets.value[0]!.id
  }

  /** Dipanggil saat aplikasi dibuka ulang: pulihkan sesi jika token masih valid. */
  async function restore(): Promise<boolean> {
    const token = await auth().getAccessToken()
    if (!token) return false
    try {
      const res = await api().get<MeResponse>('/api/auth/me', { skipAuthRedirect: true })
      me.value = res.data
      restoreContext()
      return true
    } catch {
      await auth().signOut()
      me.value = null
      return false
    }
  }

  /**
   * Login ulang dengan password user yang sama (dipakai membuka kunci terminal). Token baru
   * membawa waktu autentikasi baru; backend/database menolak unlock dengan token lama.
   */
  async function reauthenticate(password: string) {
    const email = me.value?.user.email
    if (!email) throw new Error('Belum login')
    await auth().signIn(email, password)
  }

  async function refresh() {
    const res = await api().get<MeResponse>('/api/auth/me')
    me.value = res.data
  }

  async function logout() {
    try {
      if (me.value) await api().post('/api/auth/logout', {}, { skipAuthRedirect: true })
    } catch {
      // logout lokal tetap dilakukan walaupun audit logout gagal terkirim
    }
    await auth().signOut()
    me.value = null
    clearContext()
  }

  /** Sesi kadaluarsa (401): bersihkan tanpa memanggil API. */
  async function expire() {
    await auth().signOut()
    me.value = null
    clearContext()
  }

  return {
    me, outletId, terminal, isAuthenticated, outlets, currentOutlet, roleSummary,
    can, selectContext, clearContext, login, restore, reauthenticate, refresh, logout, expire,
  }
})
