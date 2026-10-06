import { defineStore } from 'pinia'
import { api } from '@/services'
import type { ReturnLookup, SaleReturn } from '@/types/api'

/** Retur & refund. Nilai retur/refund selalu dihitung server; store hanya meneruskan pilihan kasir. */
export const useReturnStore = defineStore('returns', () => {
  async function lookup(receiptNo: string) {
    return (await api().get<ReturnLookup>('/api/returns/lookup', { query: { receiptNo } })).data
  }

  async function create(req: {
    clientReturnId: string
    originalSaleId: string
    reason: string
    refundMode: 'CASH' | 'ORIGINAL'
    refundReference?: string | null
    items: { saleItemId: string; quantity: number; returnToStock?: boolean }[]
  }, key: string) {
    return (await api().post<SaleReturn>('/api/returns', req, { idempotencyKey: key })).data
  }

  async function get(id: string) {
    return (await api().get<SaleReturn>(`/api/returns/${id}`)).data
  }

  async function list(outletId: string, status?: string) {
    return (await api().get<SaleReturn[]>('/api/returns', { query: { outletId, status } })).data
  }

  /** Supervisor memasukkan email + password di terminal kasir (password tidak disimpan). */
  async function approveAtTerminal(id: string, email: string, password: string, refundReference?: string | null) {
    return (await api().post<SaleReturn>(`/api/returns/${id}/approve-at-terminal`,
      { email, password, refundReference })).data
  }

  async function approve(id: string, refundReference: string | null, key: string) {
    return (await api().post<SaleReturn>(`/api/returns/${id}/approve`, { refundReference }, { idempotencyKey: key })).data
  }

  async function reject(id: string, reason: string, key: string) {
    return (await api().post<SaleReturn>(`/api/returns/${id}/reject`, { reason }, { idempotencyKey: key })).data
  }

  return { lookup, create, get, list, approveAtTerminal, approve, reject }
})

/** Baris retur yang dikirim: hanya jumlah > 0, dibatasi sisa yang bisa diretur. */
export function toReturnLines(
  quantities: Record<string, number | null | undefined>,
  remaining: Record<string, number>,
): { saleItemId: string; quantity: number }[] {
  return Object.entries(quantities)
    .filter(([id, q]) => q !== null && q !== undefined && q > 0 && remaining[id] !== undefined)
    .map(([saleItemId, q]) => ({ saleItemId, quantity: Math.min(q as number, remaining[saleItemId]!) }))
}
