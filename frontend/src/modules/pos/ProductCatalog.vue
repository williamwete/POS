<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import InputText from 'primevue/inputtext'
import ProgressSpinner from 'primevue/progressspinner'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import type { Product, ProductCategory } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/**
 * Katalog kasir: seluruh produk dengan foto, harga & stok outlet, dipilih per kategori atau dicari.
 * Harga & stok di sini hanya tampilan; server menghitung ulang saat barang masuk keranjang/checkout.
 */
const props = defineProps<{
  /** jumlah per produk di keranjang aktif */
  cartQty: Record<string, number>
  disabled: boolean
  /** naik setiap transaksi selesai agar stok dimuat ulang */
  refreshKey: number
}>()
const emit = defineEmits<{
  add: [product: Product]
  decrement: [product: Product]
  enter: [text: string, results: Product[]]
  camera: []
}>()

const session = useSessionStore()
const categories = ref<ProductCategory[]>([])
const categoryId = ref<string | null>(null)
const query = ref('')
const products = ref<Product[]>([])
const loading = ref(false)
const failed = ref(false)
const input = ref<{ $el: HTMLInputElement } | null>(null)
let seq = 0
let timer: number | undefined


async function loadCategories() {
  try {
    categories.value = (await api().get<ProductCategory[]>('/api/product-categories')).data
  } catch {
    categories.value = []
  }
}

async function loadProducts() {
  if (!session.outletId) return
  const mine = ++seq
  loading.value = true
  failed.value = false
  try {
    const res = await api().get<Product[]>('/api/products', {
      query: { outletId: session.outletId, q: query.value.trim() || undefined, categoryId: categoryId.value ?? undefined, limit: 200 },
    })
    if (mine !== seq) return
    products.value = res.data.map((p) => ({
      ...p,
      price: p.price === undefined || p.price === null ? undefined : Number(p.price),
      available: p.available === undefined || p.available === null ? null : Number(p.available),
    }))
  } catch {
    if (mine === seq) failed.value = true
  } finally {
    if (mine === seq) loading.value = false
  }
}

onMounted(() => {
  void loadCategories()
  void loadProducts()
})
watch(categoryId, () => void loadProducts())
watch(() => props.refreshKey, () => void loadProducts())
watch(query, () => {
  window.clearTimeout(timer)
  timer = window.setTimeout(() => void loadProducts(), 250)
})

function soldOut(p: Product) {
  return !p.allowNegativeStock && p.available !== null && p.available !== undefined && p.available <= 0
}
function sellable(p: Product) {
  return p.price !== undefined && !soldOut(p)
}
function stockLabel(p: Product) {
  if (p.available === null || p.available === undefined) return 'Stok ?'
  if (soldOut(p)) return 'Habis'
  const n = Number.isInteger(p.available) ? p.available : Math.round(p.available * 100) / 100
  return `Stok ${n.toLocaleString('id-ID')}`
}
const qtyText = (n: number) => (Number.isInteger(n) ? String(n) : n.toLocaleString('id-ID', { maximumFractionDigits: 3 }))

function onEnter() {
  emit('enter', query.value.trim(), products.value)
}

function clearQuery() {
  query.value = ''
}

defineExpose({ focus: () => (input.value?.$el as HTMLInputElement | undefined)?.focus(), clearQuery, reload: loadProducts })
</script>

<template>
  <section class="flex min-w-0 flex-col gap-4" aria-label="Katalog produk">
    <h2 class="text-xl">Category</h2>
    <div class="flex flex-wrap items-center gap-3">
      <div class="flex flex-wrap gap-3" role="tablist" aria-label="Kategori">
        <button type="button" role="tab" :aria-selected="categoryId === null"
          :class="['cat-chip', categoryId === null ? 'cat-chip-active' : '']" @click="categoryId = null">Semua</button>
        <button v-for="c in categories" :key="c.id" type="button" role="tab" :aria-selected="categoryId === c.id"
          :class="['cat-chip', categoryId === c.id ? 'cat-chip-active' : '']" @click="categoryId = c.id">{{ c.name }}</button>
      </div>
      <form role="search" class="relative ml-auto flex min-w-[16rem] flex-1 items-center gap-2 sm:max-w-sm" @submit.prevent="onEnter">
        <div class="relative flex-1">
          <i class="pi pi-search pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-faint" aria-hidden="true" />
          <label for="scan" class="sr-only">Pindai barcode atau cari produk</label>
          <InputText id="scan" ref="input" v-model="query" autocomplete="off" class="w-full !rounded-lg !border-jade-500 !py-2 !pl-9"
            placeholder="Search product" />
        </div>
        <button type="button" class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-jade-500 text-white"
          aria-label="Pindai barcode dengan kamera" title="Pindai dengan kamera" :disabled="disabled" @click="emit('camera')"><i class="pi pi-barcode" /></button>
      </form>
    </div>

    <div v-if="loading && !products.length" class="flex justify-center py-16"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>
    <p v-else-if="failed" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
      Katalog gagal dimuat. Periksa koneksi lalu coba lagi.
    </p>
    <p v-else-if="!products.length" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
      Produk tidak ditemukan<template v-if="query"> untuk “{{ query }}”</template>.
    </p>

    <ul v-else class="grid grid-cols-2 gap-5 md:grid-cols-3 xl:grid-cols-4" :aria-busy="loading">
      <li v-for="p in products" :key="p.id">
        <article :class="['flex h-full flex-col items-center rounded-xl border bg-field px-3 pb-4 pt-3 text-center',
          cartQty[p.id] ? 'border-jade-500 ring-1 ring-jade-500' : 'border-line', !sellable(p) ? 'opacity-60' : '']">
          <div class="grid h-20 w-24 place-items-center">
            <img v-if="p.imageUrl" :src="p.imageUrl" :alt="p.name" loading="lazy" class="max-h-20 max-w-full object-contain" />
            <span v-else class="grid h-14 w-14 place-items-center rounded-full bg-jade-100 text-2xl font-bold text-jade-700">{{ p.name.charAt(0) }}</span>
          </div>
          <h3 class="mt-2 line-clamp-2 min-h-[2.5rem] text-base leading-5">{{ p.name }}</h3>
          <p v-if="p.trackStock !== false" :class="['text-[10px]', soldOut(p) ? 'font-semibold text-alert-600' : '']">{{ stockLabel(p).replace('Stok', 'Stock:') }}</p>
          <p v-else-if="p.optionGroups?.length" class="text-[10px] text-ink-faint">Ada pilihan</p>
          <p class="tabular text-sm">{{ p.price !== undefined ? formatRupiah(p.price) : 'Tanpa harga' }}<span
            v-if="p.uom !== 'PCS'" class="text-xs text-ink-faint">/{{ p.uom.toLowerCase() }}</span></p>
          <button type="button" class="add-btn" :disabled="disabled || !sellable(p)" :aria-label="`Tambah ${p.name}`"
            @click="emit('add', p)">
            Add<span v-if="cartQty[p.id]" class="tabular"> · {{ qtyText(cartQty[p.id]!) }}</span>
          </button>
        </article>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.cat-chip {
  @apply rounded-lg border border-jade-500 bg-white px-6 py-1.5 text-base transition hover:bg-jade-50;
}
.cat-chip-active {
  @apply bg-jade-500 text-white hover:bg-jade-500;
}
.add-btn {
  @apply mt-2 w-[7.5rem] rounded-md bg-[#D9D9D9] py-1 text-sm transition hover:bg-jade-100 disabled:cursor-not-allowed disabled:opacity-50;
}
</style>
