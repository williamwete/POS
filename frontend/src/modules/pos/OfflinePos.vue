<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import { useSessionStore } from '@/stores/session'
import { useOfflineStore } from '@/stores/offline'
import { newClientTransactionId } from '@/stores/sale'
import { quickCashAmounts } from '@/stores/payment'
import { formatRupiah } from '@/utils/money'
import { offlineTotal, type OfflineLine } from '@/utils/offlineQueue'
import type { Product } from '@/types/api'

/**
 * Kasir saat server tidak terjangkau: katalog dari cache, hanya tunai, tanpa diskon/void/ubah harga.
 * Transaksi masuk antrean lokal dan dikirim otomatis; server menghitung ulang dan menandai selisih.
 */
const session = useSessionStore()
const offline = useOfflineStore()

const query = ref('')
const cart = ref<OfflineLine[]>([])
const cash = ref<number | null>(null)
const busy = ref(false)
const error = ref('')
const done = ref<{ total: number; change: number } | null>(null)

onMounted(() => {
  if (session.outletId) void offline.loadCatalog(session.outletId)
})

const results = computed(() => {
  const q = query.value.trim().toLowerCase()
  const all = offline.cached
  const list = q ? all.filter((p) => p.name.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q) || p.barcode === q) : all
  return list.slice(0, 60)
})
const total = computed(() => offlineTotal(cart.value))
const change = computed(() => (cash.value ?? 0) - total.value)
const quick = computed(() => quickCashAmounts(total.value))

function add(p: Product, qty = 1) {
  if (p.price === undefined) return
  const line = cart.value.find((l) => l.productId === p.id)
  if (line) line.quantity += qty
  else cart.value.push({ productId: p.id, sku: p.sku, name: p.name, quantity: qty, unitPrice: Number(p.price) })
  done.value = null
}

function inc(l: OfflineLine, d: number) {
  l.quantity = Math.max(0, Math.round((l.quantity + d) * 1000) / 1000)
  cart.value = cart.value.filter((x) => x.quantity > 0)
}

function onEnter() {
  const q = query.value.trim()
  const hit = offline.cached.find((p) => p.barcode === q || p.sku.toLowerCase() === q.toLowerCase())
  if (hit) {
    add(hit)
    query.value = ''
  }
}

async function save() {
  error.value = ''
  if (!session.outletId || !session.terminal) {
    error.value = 'Terminal belum dipilih'
    return
  }
  busy.value = true
  try {
    await offline.enqueue({
      id: newClientTransactionId(session.terminal.code), outletId: session.outletId, terminalId: session.terminal.id,
      lines: cart.value, amountReceived: cash.value ?? 0,
    })
    done.value = { total: total.value, change: change.value }
    cart.value = []
    cash.value = null
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Gagal menyimpan'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="mx-auto max-w-[1600px]">
    <div class="grid gap-6 lg:grid-cols-[1fr_24rem]">
      <section aria-label="Katalog offline" class="flex min-w-0 flex-col gap-4">
        <h1 class="text-xl font-bold">Kasir offline</h1>
        <form role="search" @submit.prevent="onEnter">
          <label for="off-q" class="sr-only">Cari produk atau pindai barcode</label>
          <InputText id="off-q" v-model="query" autocomplete="off" class="w-full" placeholder="Cari produk atau pindai barcode" />
        </form>
        <p v-if="!offline.cached.length" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
          Katalog belum tersimpan di perangkat ini. Buka halaman kasir sekali saat online agar katalog bisa dipakai offline.
        </p>
        <ul v-else class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">
          <li v-for="p in results" :key="p.id">
            <button type="button" class="flex h-full w-full flex-col items-start rounded-xl border border-line bg-field p-3 text-left"
              @click="add(p)">
              <span class="text-sm font-semibold">{{ p.name }}</span>
              <span class="tabular text-sm text-jade-700">{{ formatRupiah(p.price) }}</span>
            </button>
          </li>
        </ul>
      </section>

      <aside class="flex flex-col gap-4 rounded-xl border border-line bg-surface p-4" aria-label="Keranjang offline">
        <h2 class="text-lg font-semibold">Keranjang</h2>
        <p v-if="done" class="rounded-lg border border-jade-500 bg-jade-50 p-3 text-sm" role="status">
          Transaksi {{ formatRupiah(done.total) }} tersimpan. Kembalian <strong>{{ formatRupiah(done.change) }}</strong>.
          Struk resmi tersedia setelah terkirim ke server.
        </p>
        <p v-if="!cart.length && !done" class="text-sm text-ink-soft">Pilih produk di sebelah kiri.</p>
        <ul class="space-y-2">
          <li v-for="l in cart" :key="l.productId" class="flex items-center gap-2 text-sm">
            <span class="min-w-0 flex-1 truncate">{{ l.name }}</span>
            <button type="button" class="h-7 w-7 rounded border border-line" :aria-label="`Kurangi ${l.name}`" @click="inc(l, -1)">−</button>
            <span class="tabular w-8 text-center">{{ l.quantity }}</span>
            <button type="button" class="h-7 w-7 rounded border border-line" :aria-label="`Tambah ${l.name}`" @click="inc(l, 1)">+</button>
            <span class="tabular w-24 text-right">{{ formatRupiah(Math.round(l.quantity * l.unitPrice)) }}</span>
          </li>
        </ul>
        <div class="flex justify-between border-t border-line pt-3 text-lg font-bold">
          <span>Total</span><span class="tabular">{{ formatRupiah(total) }}</span>
        </div>
        <template v-if="cart.length">
          <label for="off-cash" class="text-sm font-semibold">Uang diterima (tunai)</label>
          <input id="off-cash" v-model.number="cash" type="number" inputmode="numeric" min="0" class="p-inputtext p-component" />
          <div class="flex flex-wrap gap-2">
            <button v-for="a in quick" :key="a" type="button" class="rounded-lg border border-line px-3 py-1 text-sm" @click="cash = a">
              {{ formatRupiah(a) }}
            </button>
          </div>
          <p v-if="cash !== null" class="text-sm">Kembalian: <strong class="tabular">{{ formatRupiah(Math.max(0, change)) }}</strong></p>
          <p v-if="error" class="text-sm text-alert-600" role="alert">{{ error }}</p>
          <Button label="Simpan transaksi" :disabled="busy || cash === null || change < 0" @click="save" />
          <p class="text-xs text-ink-faint">Mode offline: tanpa diskon, void, atau ubah harga. Server menghitung ulang saat dikirim.</p>
        </template>
      </aside>
    </div>
  </div>
</template>
