<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
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

const CATEGORY_ICON: Record<string, string> = {
  MINUMAN: 'pi pi-shopping-bag',
  MAKANAN: 'pi pi-star',
  SEMBAKO: 'pi pi-box',
  RUMAH: 'pi pi-home',
}
const total = computed(() => categories.value.reduce((n, c) => n + c.productCount, 0))

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
function stockClass(p: Product) {
  if (soldOut(p)) return 'bg-alert-600 text-white'
  if (p.available !== null && p.available !== undefined && p.available <= 10) return 'bg-amber-100 text-amber-700'
  return 'bg-white/90 text-ink-soft'
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
    <form role="search" class="relative" @submit.prevent="onEnter">
      <i class="pi pi-search pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-ink-faint" aria-hidden="true" />
      <label for="scan" class="sr-only">Pindai barcode atau cari produk</label>
      <InputText id="scan" ref="input" v-model="query" autocomplete="off" class="w-full !rounded-xl !py-3 !pl-11 !pr-24"
        placeholder="Pindai barcode, ketik nama atau SKU…" />
      <span class="absolute right-3 top-1/2 -translate-y-1/2 rounded-md border border-line px-2 py-0.5 text-xs text-ink-faint">F2</span>
    </form>

    <div class="flex gap-3 overflow-x-auto pb-1" role="tablist" aria-label="Kategori">
      <button type="button" role="tab" :aria-selected="categoryId === null"
        :class="['cat-chip', categoryId === null ? 'cat-chip-active' : '']" @click="categoryId = null">
        <span class="cat-icon"><i class="pi pi-th-large" aria-hidden="true" /></span>
        <span class="text-left">
          <span class="block text-sm font-semibold">Semua</span>
          <span class="block text-xs text-ink-faint">{{ total }} produk</span>
        </span>
      </button>
      <button v-for="c in categories" :key="c.id" type="button" role="tab" :aria-selected="categoryId === c.id"
        :class="['cat-chip', categoryId === c.id ? 'cat-chip-active' : '']" @click="categoryId = c.id">
        <span class="cat-icon"><i :class="CATEGORY_ICON[c.code] ?? 'pi pi-tag'" aria-hidden="true" /></span>
        <span class="text-left">
          <span class="block whitespace-nowrap text-sm font-semibold">{{ c.name }}</span>
          <span class="block text-xs text-ink-faint">{{ c.productCount }} produk</span>
        </span>
      </button>
    </div>

    <div v-if="loading && !products.length" class="flex justify-center py-16"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>
    <p v-else-if="failed" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
      Katalog gagal dimuat. Periksa koneksi lalu coba lagi.
    </p>
    <p v-else-if="!products.length" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
      Produk tidak ditemukan<template v-if="query"> untuk “{{ query }}”</template>.
    </p>

    <ul v-else class="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5" :aria-busy="loading">
      <li v-for="p in products" :key="p.id">
        <article
          :class="[
            'group flex h-full flex-col overflow-hidden rounded-xl border bg-surface transition',
            cartQty[p.id] ? 'border-jade-500 ring-1 ring-jade-500' : 'border-line hover:border-jade-500/60',
            !sellable(p) ? 'opacity-60' : '',
          ]"
        >
          <button type="button" class="relative block text-left disabled:cursor-not-allowed"
            :disabled="disabled || !sellable(p)" :aria-label="`Tambah ${p.name}`" @click="emit('add', p)">
            <div class="flex aspect-[4/3] items-center justify-center bg-field">
              <img v-if="p.imageUrl" :src="p.imageUrl" :alt="p.name" loading="lazy" class="h-full w-full object-contain p-2" />
              <span v-else class="grid h-16 w-16 place-items-center rounded-full bg-surface text-2xl font-bold text-jade-700">
                {{ p.name.charAt(0) }}
              </span>
            </div>
            <span :class="['absolute left-2 top-2 rounded-full px-2 py-0.5 text-[11px] font-semibold', stockClass(p)]">{{ stockLabel(p) }}</span>
            <div class="px-3 pt-2">
              <p class="text-xs text-ink-faint">{{ p.categoryName ?? 'Tanpa kategori' }}</p>
              <h3 class="line-clamp-2 min-h-[2.5rem] text-sm font-semibold leading-5">{{ p.name }}</h3>
            </div>
          </button>
          <div class="mt-auto flex flex-wrap items-center justify-between gap-x-2 gap-y-1 px-3 pb-3 pt-1">
            <span class="tabular whitespace-nowrap font-bold">{{ p.price !== undefined ? formatRupiah(p.price) : 'Tanpa harga' }}<span
              v-if="p.uom !== 'PCS'" class="text-xs font-normal text-ink-faint">/{{ p.uom.toLowerCase() }}</span></span>
            <div v-if="cartQty[p.id]" class="ml-auto flex items-center gap-1" role="group" :aria-label="`Jumlah ${p.name}`">
              <button type="button" class="qty-btn qty-btn-outline" :disabled="disabled" :aria-label="`Kurangi ${p.name}`"
                @click="emit('decrement', p)"><i class="pi pi-minus text-[10px]" /></button>
              <span class="tabular w-7 text-center text-sm font-semibold">{{ qtyText(cartQty[p.id]!) }}</span>
              <button type="button" class="qty-btn" :disabled="disabled || !sellable(p)" :aria-label="`Tambah ${p.name}`"
                @click="emit('add', p)"><i class="pi pi-plus text-[10px]" /></button>
            </div>
            <button v-else type="button" class="qty-btn ml-auto" :disabled="disabled || !sellable(p)" :aria-label="`Tambah ${p.name}`"
              @click="emit('add', p)"><i class="pi pi-plus text-[10px]" /></button>
          </div>
        </article>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.cat-chip {
  @apply flex shrink-0 items-center gap-3 rounded-xl border border-line bg-surface px-3 py-2 transition hover:border-jade-500/60;
}
.cat-chip-active {
  @apply border-jade-500 bg-jade-50 ring-1 ring-jade-500;
}
.cat-icon {
  @apply grid h-9 w-9 place-items-center rounded-lg bg-field text-jade-700;
}
.qty-btn {
  @apply grid h-7 w-7 place-items-center rounded-full bg-jade-600 text-white transition hover:bg-jade-700 disabled:cursor-not-allowed disabled:bg-line;
}
.qty-btn-outline {
  @apply border border-line bg-surface text-ink hover:bg-field;
}
</style>
