import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import { ApiError } from '@/services/apiClient'
import type { Product } from '@/types/api'
import {
  createQueue, defaultStore, offlineTotal, plain, type KeyValueStore, type OfflineLine, type OfflineSale,
} from '@/utils/offlineQueue'

export interface OfflineResult {
  sale: { id: string; receiptNo?: string; grandTotal: number }
  duplicate: boolean
  reviewReasons: string[]
}

const CATALOG = 'catalog:'

/**
 * Mode offline: status koneksi, cache katalog, dan antrean transaksi tunai (ASSUMPTIONS A3).
 * Server tetap menghitung ulang semuanya saat transaksi dikirim.
 */
export const useOfflineStore = defineStore('offline', () => {
  let store: KeyValueStore = defaultStore()
  const queue = ref<OfflineSale[]>([])
  const online = ref(typeof navigator === 'undefined' ? true : navigator.onLine)
  const syncing = ref(false)
  const cached = ref<Product[]>([])

  const pending = computed(() => queue.value.filter((q) => q.status === 'PENDING'))
  const failed = computed(() => queue.value.filter((q) => q.status === 'FAILED'))

  function useStore(s: KeyValueStore) {
    store = s
  }
  const q = () => createQueue(store)

  async function refresh() {
    queue.value = await q().list()
  }

  function setOnline(v: boolean) {
    online.value = v
  }

  /** Simpan katalog terakhir yang berhasil dimuat (hanya produk yang bisa dijual offline). */
  async function cacheCatalog(outletId: string, products: Product[]) {
    const ok = products.filter((p) => p.price !== undefined && !(p.optionGroups?.length))
    await store.set(CATALOG + outletId, plain({ at: new Date().toISOString(), products: ok }))
    cached.value = ok
  }

  async function loadCatalog(outletId: string): Promise<Product[]> {
    const v = await store.get<{ at: string; products: Product[] }>(CATALOG + outletId)
    cached.value = v?.products ?? []
    return cached.value
  }

  async function enqueue(input: {
    id: string; outletId: string; terminalId: string; lines: OfflineLine[]; amountReceived: number; note?: string
  }): Promise<OfflineSale> {
    const total = offlineTotal(input.lines)
    if (input.lines.length === 0) throw new Error('Keranjang kosong')
    if (input.amountReceived < total) throw new Error('Uang diterima kurang dari total')
    const sale: OfflineSale = {
      ...input, offlineAt: new Date().toISOString(), clientTotal: total, status: 'PENDING', attempts: 0,
    }
    await q().add(sale)
    await refresh()
    return sale
  }

  /** Kirim satu transaksi. Jaringan putus: tetap PENDING. Ditolak server: FAILED dengan pesan. */
  async function submit(sale: OfflineSale): Promise<OfflineResult | null> {
    try {
      const res = await api().post<OfflineResult>('/api/sales/offline', {
        clientTransactionId: sale.id,
        offlineAt: sale.offlineAt,
        note: sale.note,
        lines: sale.lines.map((l) => ({ productId: l.productId, quantity: l.quantity })),
        clientTotal: sale.clientTotal,
        amountReceived: sale.amountReceived,
      })
      await q().remove(sale.id)
      return res.data
    } catch (e) {
      if (e instanceof ApiError && e.status === 0) {
        online.value = false
        return null
      }
      if (e instanceof ApiError && (e.status === 401 || e.status >= 500)) {
        return null // sesi habis / server bermasalah: coba lagi nanti, jangan buang
      }
      const msg = e instanceof ApiError ? e.message : 'Gagal dikirim'
      await q().update({ ...sale, status: 'FAILED', error: msg, attempts: sale.attempts + 1 })
      return null
    }
  }

  /** Kirim seluruh antrean PENDING berurutan. Berhenti begitu jaringan putus. */
  async function syncAll(): Promise<number> {
    if (syncing.value) return 0
    syncing.value = true
    let sent = 0
    try {
      await refresh()
      for (const s of pending.value) {
        const r = await submit(s)
        if (r) sent++
        else if (!online.value) break
      }
      if (sent > 0) online.value = true
    } finally {
      syncing.value = false
      await refresh()
    }
    return sent
  }

  /** Coba lagi transaksi yang gagal (mis. setelah stok/penyebab diperbaiki). */
  async function retry(id: string) {
    const s = queue.value.find((x) => x.id === id)
    if (!s) return
    await q().update({ ...s, status: 'PENDING', error: undefined })
    await syncAll()
  }

  /** Buang transaksi gagal (konfirmasi manusia; tercatat di UI). */
  async function discard(id: string) {
    await q().remove(id)
    await refresh()
  }

  return {
    queue, online, syncing, cached, pending, failed,
    useStore, refresh, setOnline, cacheCatalog, loadCatalog, enqueue, submit, syncAll, retry, discard,
  }
})
