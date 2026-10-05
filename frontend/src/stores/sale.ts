import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type { ApprovalPayload, ApprovalResult, Product, Receipt, Sale } from '@/types/api'

/** Normalisasi angka dari JSON (BigDecimal dikirim sebagai number). */
function normalize(s: Sale): Sale {
  const num = (v: unknown) => (v === null || v === undefined ? 0 : Number(v))
  return {
    ...s,
    itemCount: num(s.itemCount), subtotal: num(s.subtotal), itemDiscountTotal: num(s.itemDiscountTotal),
    cartDiscountTotal: num(s.cartDiscountTotal), discountTotal: num(s.discountTotal), taxTotal: num(s.taxTotal),
    grandTotal: num(s.grandTotal), paidAmount: num(s.paidAmount), changeAmount: num(s.changeAmount),
    items: (s.items ?? []).map((i) => ({
      ...i, quantity: num(i.quantity), listPrice: num(i.listPrice), unitPrice: num(i.unitPrice), taxRate: num(i.taxRate),
      grossAmount: num(i.grossAmount), itemDiscountAmount: num(i.itemDiscountAmount),
      cartDiscountAmount: num(i.cartDiscountAmount), netAmount: num(i.netAmount), taxAmount: num(i.taxAmount),
    })),
    discounts: (s.discounts ?? []).map((d) => ({ ...d, discountValue: num(d.discountValue), amount: num(d.amount) })),
  }
}

/** ID transaksi dari device (§66): unik, dapat ditelusuri ke terminal. */
export function newClientTransactionId(terminalCode: string): string {
  const safe = terminalCode.replace(/[^A-Za-z0-9-]/g, '').slice(0, 24) || 'POS'
  const d = new Date()
  const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`
  return `${safe}-${ymd}-${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`
}

/**
 * Transaksi kasir yang sedang berjalan. Semua angka (harga, diskon, pajak, total, nomor struk)
 * berasal dari server; store hanya menyimpan respons terakhir.
 */
export const useSaleStore = defineStore('sale', () => {
  const sale = ref<Sale | null>(null)
  const held = ref<Sale[]>([])

  const activeItems = computed(() => sale.value?.items.filter((i) => i.status === 'ACTIVE') ?? [])
  const cartDiscount = computed(() => sale.value?.discounts.find((d) => !d.saleItemId) ?? null)
  const isDraft = computed(() => sale.value?.status === 'DRAFT')
  /** Keranjang terkunci dan menunggu pembayaran (§23). */
  const isCheckout = computed(() => sale.value?.status === 'CHECKOUT' || sale.value?.status === 'PAYMENT_PENDING')
  const isPaid = computed(() => sale.value?.status === 'PAID')

  function set(s: Sale | null) {
    sale.value = s ? normalize(s) : null
    return sale.value
  }

  async function load() {
    set((await api().get<Sale | null>('/api/sales/current')).data ?? null)
    await loadHeld()
  }

  async function loadHeld() {
    held.value = ((await api().get<Sale[]>('/api/sales/held')).data ?? []).map(normalize)
  }

  async function create(terminalCode: string, key: string) {
    return set((await api().post<Sale>('/api/sales', { clientTransactionId: newClientTransactionId(terminalCode) },
      { idempotencyKey: key })).data)!
  }

  const base = () => `/api/sales/${sale.value!.id}`

  async function addProduct(productId: string, quantity: number, key: string) {
    return set((await api().post<Sale>(`${base()}/items`, { productId, quantity }, { idempotencyKey: key })).data)
  }

  async function addBarcode(barcode: string, quantity: number, key: string) {
    return set((await api().post<Sale>(`${base()}/items`, { barcode, quantity }, { idempotencyKey: key })).data)
  }

  async function setQuantity(itemId: string, quantity: number, key: string) {
    return set((await api().post<Sale>(`${base()}/items/${itemId}/quantity`, { quantity }, { idempotencyKey: key })).data)
  }

  async function voidItem(itemId: string, reason: string, key: string) {
    return set((await api().post<Sale>(`${base()}/items/${itemId}/void`, { reason }, { idempotencyKey: key })).data)
  }

  async function overridePrice(itemId: string, unitPrice: number, reason: string, approvalId: string | undefined, key: string) {
    return set((await api().post<Sale>(`${base()}/items/${itemId}/price`, { unitPrice, reason, approvalId },
      { idempotencyKey: key })).data)
  }

  async function addDiscount(body: { saleItemId?: string; type: 'PERCENTAGE' | 'AMOUNT'; value: number; reason: string; approvalId?: string }, key: string) {
    return set((await api().post<Sale>(`${base()}/discounts`, body, { idempotencyKey: key })).data)
  }

  async function removeDiscount(discountId: string, key: string) {
    return set((await api().post<Sale>(`${base()}/discounts/${discountId}/remove`, {}, { idempotencyKey: key })).data)
  }

  async function transition(path: 'hold' | 'checkout' | 'reopen' | 'cancel', key: string) {
    const res = (await api().post<Sale>(`${base()}/${path}`, {}, { idempotencyKey: key })).data
    if (path === 'hold' || path === 'cancel') {
      set(null)
      await loadHeld()
      return null
    }
    return set(res)
  }

  async function resume(id: string, key: string) {
    set((await api().post<Sale>(`/api/sales/${id}/resume`, {}, { idempotencyKey: key })).data)
    await loadHeld()
  }

  async function voidSale(reason: string, approvalId: string | undefined, key: string) {
    await api().post<Sale>(`${base()}/void`, { reason, approvalId }, { idempotencyKey: key })
    set(null)
  }

  async function approve(payload: ApprovalPayload, email: string, password: string) {
    return (await api().post<ApprovalResult>('/api/approvals', { ...payload, email, password })).data
  }

  async function receipt(id: string) {
    return (await api().get<Receipt>(`/api/sales/${id}/receipt`)).data
  }

  async function recordPrint(id: string, key: string) {
    return (await api().post<{ printCount: number; reprint: boolean }>(`/api/sales/${id}/receipt/print`, {},
      { idempotencyKey: key })).data
  }

  async function searchProducts(outletId: string, q: string) {
    return (await api().get<Product[]>('/api/products', { query: { outletId, q, limit: 12 } })).data
  }

  function clear() {
    set(null)
  }

  function reset() {
    sale.value = null
    held.value = []
  }

  return {
    sale, held, activeItems, cartDiscount, isDraft, isCheckout, isPaid,
    apply: set, load, loadHeld, create, addProduct, addBarcode, setQuantity, voidItem, overridePrice, addDiscount, removeDiscount,
    transition, resume, voidSale, approve, receipt, recordPrint, searchProducts, clear, reset,
  }
})
