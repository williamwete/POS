import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type { Payment, PaymentMethod, PaymentResult } from '@/types/api'
import { useSaleStore } from './sale'

function normalize(p: Payment): Payment {
  const num = (v: unknown) => (v === null || v === undefined ? 0 : Number(v))
  return { ...p, amount: num(p.amount), amountReceived: num(p.amountReceived), changeAmount: num(p.changeAmount) }
}

/** ID pembayaran dari device (§66): kirim ulang dengan ID sama = pembayaran yang sama, tidak ganda. */
export function newClientPaymentId(): string {
  return `PAY-${crypto.randomUUID().replace(/-/g, '')}`
}

/**
 * Pembayaran untuk transaksi yang sedang dibuka. Jumlah diterapkan, kembalian, dan status lunas
 * ditentukan server; store menyimpan respons terakhir dan menyinkronkan transaksi di store sale.
 */
export const usePaymentStore = defineStore('payment', () => {
  const methods = ref<PaymentMethod[]>([])
  const payments = ref<Payment[]>([])
  const simulated = ref(false)

  const paidTotal = computed(() => payments.value.filter((p) => p.status === 'PAID').reduce((a, p) => a + p.amount, 0))
  const pending = computed(() => payments.value.filter((p) => p.status === 'PENDING'))

  async function loadMethods() {
    methods.value = (await api().get<PaymentMethod[]>('/api/payment-methods')).data
    return methods.value
  }

  async function load(saleId: string) {
    payments.value = (await api().get<Payment[]>(`/api/sales/${saleId}/payments`)).data.map(normalize)
  }

  function apply(r: PaymentResult): PaymentResult {
    const p = normalize(r.payment)
    const i = payments.value.findIndex((x) => x.id === p.id)
    if (i >= 0) payments.value[i] = p
    else payments.value.push(p)
    simulated.value = r.simulated
    useSaleStore().apply(r.sale)
    return { ...r, payment: p }
  }

  async function add(
    saleId: string,
    body: { clientPaymentId: string; methodCode: string; amount?: number; amountReceived?: number; referenceNumber?: string; approvalId?: string },
    key: string,
  ) {
    return apply((await api().post<PaymentResult>(`/api/sales/${saleId}/payments`, body, { idempotencyKey: key })).data)
  }

  async function refresh(paymentId: string) {
    return apply((await api().get<PaymentResult>(`/api/payments/${paymentId}`)).data)
  }

  async function cancel(paymentId: string, reason: string, key: string) {
    return apply((await api().post<PaymentResult>(`/api/payments/${paymentId}/cancel`, { reason }, { idempotencyKey: key })).data)
  }

  async function confirm(paymentId: string, referenceNumber: string, approvalId: string, key: string) {
    return apply((await api().post<PaymentResult>(`/api/payments/${paymentId}/confirm`, { referenceNumber, approvalId },
      { idempotencyKey: key })).data)
  }

  /** Hanya pengembangan (gateway simulator). */
  async function simulate(paymentId: string, result: 'PAID' | 'FAILED') {
    return apply((await api().post<PaymentResult>(`/api/dev-payments/${paymentId}/simulate`, { result })).data)
  }

  function reset() {
    payments.value = []
    simulated.value = false
  }

  return { methods, payments, simulated, paidTotal, pending, loadMethods, load, add, refresh, cancel, confirm, simulate, reset }
})

/** Nominal uang tunai cepat: uang pas lalu pecahan/kelipatan di atas sisa tagihan. */
export function quickCashAmounts(remaining: number): number[] {
  if (remaining <= 0) return []
  const out = new Set<number>([remaining])
  for (const step of [1000, 5000, 10000, 50000, 100000]) {
    const v = Math.ceil(remaining / step) * step
    if (v > remaining) out.add(v)
  }
  for (const note of [20000, 50000, 100000]) if (note > remaining) out.add(note)
  return [...out].sort((a, b) => a - b).slice(0, 5)
}
