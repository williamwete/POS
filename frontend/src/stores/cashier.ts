import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type {
  CashApprovalAction, CashApprovalResult, CashCount, CashierSession, CashMovement, ClosePreview, CloseRequest,
  CountLine, Denomination, SessionTransaction, ShiftReport,
} from '@/types/api'

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

  // ---- Phase 6: kas masuk/keluar, penyesuaian, tutup kasir

  async function cashMovement(type: 'CASH_IN' | 'CASH_OUT' | 'PETTY_CASH', amount: number, reason: string,
    approvalId: string | null, key: string) {
    const s = requireCurrent()
    return (await api().post<CashMovement>(`/api/cashier/sessions/${s.id}/cash-movements`,
      { type, amount, reason, approvalId }, { idempotencyKey: key })).data
  }

  async function movements(sessionId: string) {
    return (await api().get<CashMovement[]>(`/api/cashier/sessions/${sessionId}/movements`)).data
      .map((m) => ({ ...m, amount: Number(m.amount) }))
  }

  async function adjustment(sessionId: string, amount: number, reason: string, key: string) {
    return (await api().post<CashMovement>(`/api/cashier/sessions/${sessionId}/adjustments`,
      { amount, reason }, { idempotencyKey: key })).data
  }

  async function get(sessionId: string) {
    return (await api().get<CashierSession>(`/api/cashier/sessions/${sessionId}`)).data
  }

  async function closePreview(sessionId: string, counts: CountLine[]) {
    const p = (await api().post<ClosePreview>(`/api/cashier/sessions/${sessionId}/close/preview`, { counts })).data
    return {
      ...p,
      countedCash: Number(p.countedCash),
      expectedCash: Number(p.expectedCash),
      difference: Number(p.difference),
      approvalThreshold: Number(p.approvalThreshold),
    }
  }

  async function close(sessionId: string, req: CloseRequest, key: string) {
    const closed = (await api().post<CashierSession>(`/api/cashier/sessions/${sessionId}/close`, req,
      { idempotencyKey: key })).data
    if (current.value?.id === sessionId) current.value = null
    return closed
  }

  /** Approval supervisor (email + password approver; password tidak disimpan). */
  async function approveCash(sessionId: string, action: CashApprovalAction, amount: number, email: string,
    password: string) {
    return (await api().post<CashApprovalResult>('/api/cashier/approvals',
      { sessionId, action, amount, email, password })).data
  }

  // ---- Phase 7: laporan closing

  async function xReport(sessionId: string) {
    return (await api().post<ShiftReport>(`/api/cashier/sessions/${sessionId}/x-report`, {})).data
  }

  async function zReport(sessionId: string) {
    return (await api().get<ShiftReport>(`/api/cashier/sessions/${sessionId}/z-report`)).data
  }

  async function recordZPrint(sessionId: string) {
    await api().post(`/api/cashier/sessions/${sessionId}/z-report/print`, {})
  }

  async function transactions(sessionId: string) {
    return (await api().get<SessionTransaction[]>(`/api/cashier/sessions/${sessionId}/transactions`)).data
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
    cashMovement, movements, adjustment, get, closePreview, close, approveCash,
    xReport, zReport, recordZPrint, transactions,
  }
})

/** Ubah jumlah per denominasi menjadi baris request (baris 0 tetap dikirim agar rincian lengkap). */
export function toCountLines(quantities: Record<string, number | null | undefined>): CountLine[] {
  return Object.entries(quantities)
    .filter(([, q]) => q !== null && q !== undefined && q >= 0)
    .map(([denominationId, q]) => ({ denominationId, quantity: Math.floor(q as number) }))
}
