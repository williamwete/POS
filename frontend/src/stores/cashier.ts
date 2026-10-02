import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type { CashCount, CashierSession, CountLine, Denomination } from '@/types/api'

/**
 * Cashier session milik user yang login. Semua angka uang (modal awal, total hitungan)
 * dihitung server dari master denominasi; store hanya menyimpan hasil terakhir.
 */
export const useCashierStore = defineStore('cashier', () => {
  const current = ref<CashierSession | null>(null)
  const denominations = ref<Denomination[]>([])
  const loaded = ref(false)

  const isOpen = computed(() => current.value?.status === 'OPEN')
  const isLocked = computed(() => current.value?.status === 'ON_BREAK')

  async function load() {
    current.value = (await api().get<CashierSession | null>('/api/cashier/sessions/current')).data ?? null
    loaded.value = true
  }

  async function loadDenominations() {
    if (denominations.value.length) return denominations.value
    denominations.value = (await api().get<Denomination[]>('/api/cashier/denominations')).data.map((d) => ({
      ...d,
      value: Number(d.value),
    }))
    return denominations.value
  }

  async function open(terminalId: string, counts: CountLine[], note: string | null, key: string) {
    current.value = (
      await api().post<CashierSession>('/api/cashier/sessions/open', { terminalId, counts, note }, { idempotencyKey: key })
    ).data
    return current.value
  }

  async function cashCount(counts: CountLine[], note: string | null, key: string) {
    const s = requireCurrent()
    const res = await api().post<CashCount>(`/api/cashier/sessions/${s.id}/cash-count`, { counts, note }, { idempotencyKey: key })
    await load()
    return res.data
  }

  async function lock(reason: 'MANUAL' | 'IDLE', key: string) {
    const s = requireCurrent()
    current.value = (await api().post<CashierSession>(`/api/cashier/sessions/${s.id}/lock`, { reason }, { idempotencyKey: key })).data
  }

  async function unlock(key: string) {
    const s = requireCurrent()
    current.value = (await api().post<CashierSession>(`/api/cashier/sessions/${s.id}/unlock`, {}, { idempotencyKey: key })).data
  }

  async function cancel(reason: string, key: string) {
    const s = requireCurrent()
    await api().post<CashierSession>(`/api/cashier/sessions/${s.id}/cancel`, { reason }, { idempotencyKey: key })
    current.value = null
  }

  function requireCurrent(): CashierSession {
    if (!current.value) throw new Error('Tidak ada cashier session aktif')
    return current.value
  }

  function reset() {
    current.value = null
    loaded.value = false
  }

  return {
    current, denominations, loaded, isOpen, isLocked,
    load, loadDenominations, open, cashCount, lock, unlock, cancel, reset,
  }
})

/** Ubah jumlah per denominasi menjadi baris request (baris 0 tetap dikirim agar rincian lengkap). */
export function toCountLines(quantities: Record<string, number | null | undefined>): CountLine[] {
  return Object.entries(quantities)
    .filter(([, q]) => q !== null && q !== undefined && q >= 0)
    .map(([denominationId, q]) => ({ denominationId, quantity: Math.floor(q as number) }))
}
