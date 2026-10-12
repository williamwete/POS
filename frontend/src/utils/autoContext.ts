import { api } from '@/services'
import { useCashierStore } from '@/stores/cashier'
import { useSessionStore } from '@/stores/session'
import type { Terminal } from '@/types/api'

/**
 * Pilih outlet & terminal otomatis setelah login (alur Figma: login → langsung kasir).
 * Urutan: konteks yang sudah tersimpan → terminal kasir yang masih terbuka → satu-satunya outlet
 * dengan terminal aktif pertama. Bila masih ambigu, mengembalikan false (tampilkan halaman pilih).
 */
export async function autoSelectContext(): Promise<boolean> {
  const session = useSessionStore()
  if (session.outletId && session.terminal) return true
  try {
    if (session.me?.employee) {
      const cashier = useCashierStore()
      await cashier.load().catch(() => undefined)
      const s = cashier.current
      if (s && session.outlets.some((o) => o.id === s.outletId)) {
        session.selectContext(s.outletId, { id: s.terminalId, code: s.terminalCode, name: s.terminalName })
        return true
      }
    }
    const outlets = session.outlets.filter((o) => o.active)
    if (outlets.length !== 1) return false
    const terminals = (await api().get<Terminal[]>('/api/terminals', { query: { outletId: outlets[0]!.id } })).data
      .filter((t) => t.active)
    // Figma tidak punya langkah pilih terminal: ambil terminal aktif pertama (kode terkecil).
    // Perangkat lain dapat memilih terminal berbeda lewat ikon "Ganti outlet / terminal" di header.
    terminals.sort((a, b) => a.code.localeCompare(b.code))
    if (terminals.length < 1) return false
    session.selectContext(outlets[0]!.id, { id: terminals[0]!.id, code: terminals[0]!.code, name: terminals[0]!.name })
    return true
  } catch {
    return false
  }
}
