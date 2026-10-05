<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Menu from 'primevue/menu'
import ProgressSpinner from 'primevue/progressspinner'
import { useToast } from 'primevue/usetoast'
import { useSessionStore } from '@/stores/session'
import { useCashierStore } from '@/stores/cashier'
import { useSaleStore } from '@/stores/sale'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'
import { formatNumber, formatRupiah } from '@/utils/money'
import type { ApprovalPayload, Product, SaleItem } from '@/types/api'
import { useApprovalPrompt } from './approvalPrompt'
import ApprovalDialog from './ApprovalDialog.vue'
import DiscountDialog from './DiscountDialog.vue'
import PriceDialog from './PriceDialog.vue'
import ReasonDialog from './ReasonDialog.vue'
import HeldSalesDialog from './HeldSalesDialog.vue'
import ReceiptDialog from './ReceiptDialog.vue'
import PaymentPanel from './PaymentPanel.vue'
import PaidPanel from './PaidPanel.vue'
import { usePaymentStore } from '@/stores/payment'

const session = useSessionStore()
const cashier = useCashierStore()
const sales = useSaleStore()
const payments = usePaymentStore()
const router = useRouter()
const toast = useToast()
const prompt = useApprovalPrompt()

const loading = ref(true)
const busy = ref(false)
const scan = ref('')
const scanInput = ref<{ $el: HTMLInputElement } | null>(null)
const results = ref<Product[]>([])
const searched = ref(false)

const s = computed(() => sales.sale)
const items = computed(() => sales.activeItems)
const sessionOk = computed(
  () => cashier.current?.status === 'OPEN' && cashier.current.terminalId === session.terminal?.id,
)
// pembayaran milik transaksi yang sedang dibuka; ganti transaksi = kosongkan
watch(() => sales.sale?.id, (id, old) => {
  if (id !== old) payments.reset()
})

/** Selesai: lanjut ke transaksi berikutnya (pemindaian membuat transaksi baru). */
function nextSale() {
  sales.clear()
  payments.reset()
  focusScan()
}

const discountOf = (item: SaleItem) => s.value?.discounts.find((d) => d.saleItemId === item.id) ?? null

onMounted(async () => {
  try {
    await cashier.load()
    if (cashier.current) await sales.load()
  } catch (e) {
    notify(e)
  } finally {
    loading.value = false
    focusScan()
  }
  window.addEventListener('keydown', onKey)
})
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))

function focusScan() {
  void nextTick(() => (scanInput.value?.$el as HTMLInputElement | undefined)?.focus())
}

function onKey(e: KeyboardEvent) {
  if (e.key === 'F2') {
    e.preventDefault()
    if (sales.isPaid) nextSale()
    focusScan()
  } else if (e.key === 'F4' && sales.isDraft && items.value.length) {
    e.preventDefault()
    void hold()
  } else if (e.key === 'F9' && sales.isDraft && items.value.length) {
    e.preventDefault()
    void checkout()
  }
}

function notify(e: unknown) {
  const msg = e instanceof ApiError ? e.message : 'Terjadi kesalahan tak terduga.'
  toast.add({ severity: 'error', summary: msg, detail: e instanceof ApiError && e.requestId ? `Kode request: ${e.requestId}` : undefined, life: 5000 })
}

/**
 * Menjalankan aksi kasir. Bila server menjawab APPROVAL_REQUIRED, dialog supervisor dibuka lalu aksi
 * diulang dengan approvalId. Setiap percobaan memakai idempotency key sendiri.
 */
async function act<T>(
  fn: (key: string, approvalId?: string) => Promise<T>,
  opts: { approval?: () => ApprovalPayload; success?: string; quiet?: string[] } = {},
): Promise<T | null> {
  if (busy.value) return null
  busy.value = true
  try {
    try {
      const r = await fn(newIdempotencyKey())
      if (opts.success) toast.add({ severity: 'success', summary: opts.success, life: 2000 })
      return r
    } catch (e) {
      if (!(opts.approval && e instanceof ApiError && e.code === 'APPROVAL_REQUIRED')) throw e
      busy.value = false
      const approvalId = await prompt.ask(opts.approval(), e.message)
      if (!approvalId) return null
      busy.value = true
      const r = await fn(newIdempotencyKey(), approvalId)
      if (opts.success) toast.add({ severity: 'success', summary: opts.success, life: 2000 })
      return r
    }
  } catch (e) {
    if (!(e instanceof ApiError && opts.quiet?.includes(e.code))) notify(e)
    return null
  } finally {
    busy.value = false
    focusScan()
  }
}

async function ensureSale(key: string) {
  if (!sales.sale || sales.sale.status !== 'DRAFT') {
    await sales.create(session.terminal!.code, `${key}-new`)
  }
}

// ---------------------------------------------------------------- scan / cari
async function onScan() {
  const text = scan.value.trim()
  if (!text || !session.outletId) return
  if (/^[0-9]{6,14}$/.test(text)) {
    // barcode tidak dikenal -> lanjut sebagai pencarian teks (tanpa pesan error)
    const added = await act(async (key) => {
      await ensureSale(key)
      return sales.addBarcode(text, 1, key)
    }, { quiet: ['PRODUCT_NOT_FOUND'] })
    if (added) {
      scan.value = ''
      results.value = []
      searched.value = false
      return
    }
  }
  try {
    results.value = await sales.searchProducts(session.outletId, text)
    searched.value = true
    if (results.value.length === 1 && results.value[0]!.sku.toLowerCase() === text.toLowerCase()) {
      await addProduct(results.value[0]!)
    }
  } catch (e) {
    notify(e)
  }
}

async function addProduct(p: Product) {
  const ok = await act(async (key) => {
    await ensureSale(key)
    return sales.addProduct(p.id, 1, key)
  })
  if (ok) {
    scan.value = ''
    results.value = []
    searched.value = false
  }
}

// ---------------------------------------------------------------- baris
function changeQty(item: SaleItem, delta: number) {
  const q = Math.round((item.quantity + delta) * 1000) / 1000
  if (q <= 0) {
    openVoidItem(item)
    return
  }
  void act((key) => sales.setQuantity(item.id, q, key))
}

function setQty(item: SaleItem, ev: Event) {
  const raw = (ev.target as HTMLInputElement).value.replace(',', '.')
  const q = Number(raw)
  if (!Number.isFinite(q) || q <= 0 || q === item.quantity) {
    ;(ev.target as HTMLInputElement).value = String(item.quantity)
    return
  }
  void act((key) => sales.setQuantity(item.id, q, key))
}

const lineMenu = ref<InstanceType<typeof Menu> | null>(null)
const menuItem = ref<SaleItem | null>(null)
const menuModel = computed(() => {
  const it = menuItem.value
  if (!it) return []
  const d = discountOf(it)
  return [
    d
      ? { label: 'Hapus diskon barang', icon: 'pi pi-times', command: () => removeDiscount(d.id) }
      : { label: 'Diskon barang', icon: 'pi pi-percentage', command: () => openItemDiscount(it) },
    { label: 'Ubah harga', icon: 'pi pi-tag', command: () => openPrice(it) },
    { separator: true },
    { label: 'Batalkan barang', icon: 'pi pi-trash', class: 'text-alert-600', command: () => openVoidItem(it) },
  ]
})
function openMenu(e: Event, item: SaleItem) {
  menuItem.value = item
  lineMenu.value?.toggle(e)
}

// diskon
const discountVisible = ref(false)
const discountTarget = ref<SaleItem | null>(null)
const discountBase = computed(() =>
  discountTarget.value
    ? discountTarget.value.grossAmount
    : items.value.reduce((n, i) => n + i.grossAmount - i.itemDiscountAmount, 0),
)
function openItemDiscount(item: SaleItem) {
  discountTarget.value = item
  discountVisible.value = true
}
function openCartDiscount() {
  discountTarget.value = null
  discountVisible.value = true
}
async function applyDiscount(d: { type: 'PERCENTAGE' | 'AMOUNT'; value: number; reason: string }) {
  const saleItemId = discountTarget.value?.id
  const ok = await act(
    (key, approvalId) => sales.addDiscount({ saleItemId, ...d, approvalId }, key),
    {
      approval: () => ({ action: 'DISCOUNT', saleId: s.value!.id, saleItemId, discountType: d.type, discountValue: d.value }),
      success: 'Diskon diterapkan',
    },
  )
  if (ok) discountVisible.value = false
}
function removeDiscount(id: string) {
  void act((key) => sales.removeDiscount(id, key), { success: 'Diskon dihapus' })
}

// ubah harga
const priceVisible = ref(false)
const priceItem = ref<SaleItem | null>(null)
function openPrice(item: SaleItem) {
  priceItem.value = item
  priceVisible.value = true
}
async function applyPrice(d: { price: number; reason: string }) {
  const item = priceItem.value!
  const ok = await act(
    (key, approvalId) => sales.overridePrice(item.id, d.price, d.reason, approvalId, key),
    { approval: () => ({ action: 'PRICE_OVERRIDE', saleId: s.value!.id, saleItemId: item.id, price: d.price }), success: 'Harga diubah' },
  )
  if (ok) priceVisible.value = false
}

// void barang
const voidItemVisible = ref(false)
const voidItemTarget = ref<SaleItem | null>(null)
function openVoidItem(item: SaleItem) {
  voidItemTarget.value = item
  voidItemVisible.value = true
}
async function confirmVoidItem(reason: string) {
  const ok = await act((key) => sales.voidItem(voidItemTarget.value!.id, reason, key), { success: 'Barang dibatalkan' })
  if (ok) voidItemVisible.value = false
}

// ---------------------------------------------------------------- transaksi
async function hold() {
  await act((key) => sales.transition('hold', key), { success: 'Transaksi ditahan' })
}

async function checkout() {
  await act((key) => sales.transition('checkout', key), { success: 'Checkout berhasil' })
}

async function reopen() {
  await act((key) => sales.transition('reopen', key))
}

const heldVisible = ref(false)
async function openHeld() {
  await act(() => sales.loadHeld())
  heldVisible.value = true
}
async function resume(id: string) {
  const ok = await act(async (key) => {
    // keranjang kosong yang terbuka dibatalkan dulu agar transaksi ditahan bisa dilanjutkan
    if (sales.sale?.status === 'DRAFT' && sales.activeItems.length === 0) await sales.transition('cancel', `${key}-c`)
    await sales.resume(id, key)
    return true
  }, { success: 'Transaksi dilanjutkan' })
  if (ok) heldVisible.value = false
}

const voidSaleVisible = ref(false)
async function confirmVoidSale(reason: string) {
  const ok = await act(
    async (key, approvalId) => {
      await sales.voidSale(reason, approvalId, key)
      return true
    },
    { approval: () => ({ action: 'VOID_SALE', saleId: s.value!.id }), success: 'Transaksi di-void' },
  )
  if (ok) voidSaleVisible.value = false
}

async function cancelEmpty() {
  await act((key) => sales.transition('cancel', key))
}

const receiptVisible = ref(false)

const unitLabel = (item: SaleItem) => (item.uom === 'PCS' ? '' : ` ${item.uom.toLowerCase()}`)
const qtyText = (n: number) => (Number.isInteger(n) ? String(n) : n.toLocaleString('id-ID', { maximumFractionDigits: 3 }))
</script>

<template>
  <div class="mx-auto max-w-7xl">
    <div v-if="loading" class="flex justify-center p-10"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <!-- prasyarat: kasir dibuka di terminal ini -->
    <div v-else-if="!sessionOk" class="mx-auto max-w-xl rounded-lg border border-amber-500 bg-amber-100 p-6">
      <h1 class="text-xl font-bold">Kasir belum siap</h1>
      <p v-if="!cashier.current" class="mt-2 text-sm">Buka kasir (hitung modal awal) di terminal ini sebelum bertransaksi.</p>
      <p v-else-if="cashier.current.terminalId !== session.terminal?.id" class="mt-2 text-sm">
        Session kasir Anda terbuka di <strong class="tabular">{{ cashier.current.terminalCode }}</strong>, bukan di
        <span class="tabular">{{ session.terminal?.code }}</span>.
      </p>
      <p v-else class="mt-2 text-sm">Terminal sedang terkunci.</p>
      <div class="mt-4 flex gap-2">
        <Button v-if="!cashier.current" label="Buka kasir" icon="pi pi-lock-open" @click="router.push({ name: 'cashier-open' })" />
        <Button v-else-if="cashier.current.terminalId !== session.terminal?.id" :label="`Pindah ke ${cashier.current.terminalCode}`"
          @click="session.selectContext(cashier.current!.outletId, { id: cashier.current!.terminalId, code: cashier.current!.terminalCode, name: cashier.current!.terminalName })" />
      </div>
    </div>

    <div v-else class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem]">
      <!-- ============================ keranjang -->
      <section class="flex min-h-[60vh] flex-col rounded-lg border border-line bg-surface" aria-labelledby="cart-title">
        <header class="flex flex-wrap items-center justify-between gap-2 border-b border-line px-4 py-3">
          <div>
            <h1 id="cart-title" class="text-lg font-bold">Keranjang</h1>
            <p class="text-xs text-ink-soft">
              <template v-if="s?.receiptNo">Struk <span class="tabular font-semibold text-ink">{{ s.receiptNo }}</span> · </template>
              {{ items.length }} baris · {{ qtyText(s?.itemCount ?? 0) }} item
            </p>
          </div>
          <Button
            :label="`Ditahan (${sales.held.length})`"
            icon="pi pi-inbox"
            severity="secondary"
            size="small"
            outlined
            :disabled="busy"
            @click="openHeld"
          />
        </header>

        <div v-if="items.length === 0" class="flex flex-1 flex-col items-center justify-center p-10 text-center text-ink-soft">
          <i class="pi pi-barcode text-4xl text-ink-faint" aria-hidden="true" />
          <p class="mt-3 font-medium text-ink">Pindai barcode atau cari produk</p>
          <p class="text-sm">Tekan F2 untuk kembali ke kolom pindai.</p>
        </div>

        <ol v-else class="flex-1 divide-y divide-line overflow-y-auto">
          <li v-for="item in items" :key="item.id" class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-3 gap-y-2 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto_7.5rem_auto]">
            <div class="min-w-0">
              <div class="truncate font-semibold">{{ item.productName }}</div>
              <div class="text-xs text-ink-soft">
                <span class="tabular">{{ item.sku }}</span> ·
                <span class="tabular">{{ formatRupiah(item.unitPrice) }}</span>{{ unitLabel(item) }}
                <s v-if="item.unitPrice !== item.listPrice" class="tabular text-ink-faint">{{ formatRupiah(item.listPrice) }}</s>
                <span v-if="item.taxRate === 0" class="ml-1 rounded bg-field px-1">bebas PPN</span>
              </div>
              <div v-if="discountOf(item)" class="mt-1 inline-flex items-center gap-1 rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-700">
                <i class="pi pi-percentage text-[10px]" aria-hidden="true" />
                {{ discountOf(item)!.discountType === 'PERCENTAGE' ? `${formatNumber(discountOf(item)!.discountValue)}%` : formatRupiah(discountOf(item)!.discountValue) }}
                · {{ discountOf(item)!.reason }}
                <template v-if="discountOf(item)!.approvedByUsername"> · disetujui {{ discountOf(item)!.approvedByUsername }}</template>
              </div>
              <div v-if="item.priceOverrideReason" class="mt-1 text-xs text-amber-700">Harga diubah: {{ item.priceOverrideReason }}</div>
            </div>

            <div class="flex items-center self-center" role="group" :aria-label="`Jumlah ${item.productName}`">
              <Button icon="pi pi-minus" text rounded size="small" :disabled="busy || !sales.isDraft" aria-label="Kurangi" @click="changeQty(item, -1)" />
              <input
                :value="qtyText(item.quantity)"
                class="tabular w-12 rounded border border-line py-1 text-center text-sm"
                :disabled="busy || !sales.isDraft"
                :aria-label="`Jumlah ${item.productName}`"
                inputmode="decimal"
                @change="(e) => setQty(item, e)"
              />
              <Button icon="pi pi-plus" text rounded size="small" :disabled="busy || !sales.isDraft" aria-label="Tambah" @click="changeQty(item, 1)" />
            </div>

            <div class="col-start-1 text-right sm:col-start-auto">
              <div class="tabular font-semibold">{{ formatRupiah(item.netAmount) }}</div>
              <div v-if="item.itemDiscountAmount + item.cartDiscountAmount > 0" class="tabular text-xs text-ink-faint">
                <s>{{ formatRupiah(item.grossAmount) }}</s>
              </div>
            </div>
            <Button icon="pi pi-ellipsis-v" text rounded size="small" :disabled="busy || !sales.isDraft"
              :aria-label="`Aksi ${item.productName}`" class="self-center" @click="(e) => openMenu(e, item)" />
          </li>
        </ol>

        <footer v-if="sales.cartDiscount" class="flex items-center justify-between gap-2 border-t border-line bg-amber-100 px-4 py-2 text-sm">
          <span>
            Diskon transaksi
            {{ sales.cartDiscount.discountType === 'PERCENTAGE' ? `${formatNumber(sales.cartDiscount.discountValue)}%` : formatRupiah(sales.cartDiscount.discountValue) }}
            · {{ sales.cartDiscount.reason }}
            <template v-if="sales.cartDiscount.approvedByUsername"> · disetujui {{ sales.cartDiscount.approvedByUsername }}</template>
          </span>
          <Button v-if="sales.isDraft" label="Hapus" text size="small" :disabled="busy" @click="removeDiscount(sales.cartDiscount!.id)" />
        </footer>
        <Menu ref="lineMenu" :model="menuModel" popup />
      </section>

      <!-- ============================ panel kanan -->
      <aside class="flex flex-col gap-4">
        <template v-if="!sales.isCheckout && !sales.isPaid">
          <form class="rounded-lg border border-line bg-surface p-4" role="search" @submit.prevent="onScan">
            <label for="scan" class="mb-1 block text-sm font-semibold">Pindai / cari produk <span class="text-xs font-normal text-ink-faint">(F2)</span></label>
            <div class="flex gap-2">
              <InputText id="scan" ref="scanInput" v-model="scan" class="tabular w-full" autocomplete="off"
                placeholder="Barcode, SKU, atau nama" :disabled="busy" />
              <Button type="submit" icon="pi pi-search" aria-label="Cari" :loading="busy" />
            </div>
            <ul v-if="results.length" class="mt-3 max-h-72 divide-y divide-line overflow-y-auto rounded-md border border-line">
              <li v-for="p in results" :key="p.id">
                <button type="button" class="flex w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-field disabled:opacity-50"
                  :disabled="busy || p.price === undefined || p.price === null" @click="addProduct(p)">
                  <span class="min-w-0">
                    <span class="block truncate text-sm font-semibold">{{ p.name }}</span>
                    <span class="tabular block text-xs text-ink-soft">
                      {{ p.sku }} · stok {{ p.available === null || p.available === undefined ? '?' : qtyText(Number(p.available)) }}
                    </span>
                  </span>
                  <span class="tabular shrink-0 text-sm font-semibold">{{ p.price !== undefined && p.price !== null ? formatRupiah(p.price) : 'Tanpa harga' }}</span>
                </button>
              </li>
            </ul>
            <p v-else-if="searched" class="mt-3 text-sm text-ink-soft">Produk tidak ditemukan.</p>
          </form>
        </template>

        <section class="rounded-lg border border-line bg-surface" aria-label="Ringkasan">
          <dl class="space-y-1 p-4 text-sm">
            <div class="flex justify-between"><dt class="text-ink-soft">Subtotal</dt><dd class="tabular">{{ formatRupiah(s?.subtotal ?? 0) }}</dd></div>
            <div class="flex justify-between"><dt class="text-ink-soft">Diskon</dt><dd class="tabular">−{{ formatRupiah(s?.discountTotal ?? 0) }}</dd></div>
            <div class="flex justify-between">
              <dt class="text-ink-soft">PPN{{ s?.pricesIncludeTax !== false ? ' (termasuk harga)' : '' }}</dt>
              <dd class="tabular">{{ formatRupiah(s?.taxTotal ?? 0) }}</dd>
            </div>
          </dl>
          <div class="flex items-end justify-between rounded-b-lg bg-jade-700 px-4 py-3 text-white">
            <span class="text-sm text-jade-100">Total</span>
            <output class="tabular text-3xl font-bold tracking-tight" aria-live="polite">{{ formatRupiah(s?.grandTotal ?? 0) }}</output>
          </div>
        </section>

        <!-- aksi keranjang -->
        <div v-if="!sales.isCheckout && !sales.isPaid" class="grid grid-cols-2 gap-2">
          <Button label="Diskon transaksi" icon="pi pi-percentage" severity="secondary" outlined
            :disabled="busy || !sales.isDraft || items.length === 0 || !!sales.cartDiscount" @click="openCartDiscount" />
          <Button label="Tahan (F4)" icon="pi pi-pause" severity="secondary" outlined
            :disabled="busy || !sales.isDraft || items.length === 0" @click="hold" />
          <Button v-if="s && items.length === 0 && sales.isDraft" label="Batalkan" icon="pi pi-times" severity="secondary" text
            class="col-span-2" :disabled="busy" @click="cancelEmpty" />
          <Button v-else label="Void transaksi" icon="pi pi-ban" severity="danger" text class="col-span-2"
            :disabled="busy || !s || !sales.isDraft" @click="voidSaleVisible = true" />
          <Button label="Checkout (F9)" icon="pi pi-arrow-right" icon-pos="right" size="large" class="col-span-2"
            :disabled="busy || !sales.isDraft || items.length === 0" :loading="busy" @click="checkout" />
        </div>

        <!-- setelah checkout: pembayaran (Phase 5) -->
        <PaymentPanel v-else-if="sales.isCheckout" :key="s?.id" @reopen="reopen" @void="voidSaleVisible = true"
          @receipt="receiptVisible = true" />
        <PaidPanel v-else @receipt="receiptVisible = true" @next="nextSale" />
      </aside>
    </div>

    <ApprovalDialog />
    <DiscountDialog v-model:visible="discountVisible" :title="discountTarget ? `Diskon · ${discountTarget.productName}` : 'Diskon transaksi'"
      :base="discountBase" :busy="busy" @confirm="applyDiscount" />
    <PriceDialog v-model:visible="priceVisible" :item="priceItem" :busy="busy" @confirm="applyPrice" />
    <ReasonDialog v-model:visible="voidItemVisible" :title="`Batalkan ${voidItemTarget?.productName ?? 'barang'}`"
      description="Barang dihapus dari keranjang dan tetap tercatat sebagai void beserta alasannya."
      :presets="['Salah scan', 'Pelanggan batal', 'Barang rusak']" :min-length="3" confirm-label="Batalkan barang"
      :busy="busy" @confirm="confirmVoidItem" />
    <ReasonDialog v-model:visible="voidSaleVisible" title="Void transaksi"
      :description="sales.isCheckout ? 'Transaksi yang sudah checkout memerlukan persetujuan supervisor. Nomor struk tetap tercatat sebagai VOID.' : 'Seluruh keranjang dibatalkan dan tercatat sebagai VOID.'"
      :presets="['Pelanggan batal membeli', 'Salah input transaksi', 'Uang pelanggan kurang']" :min-length="5"
      confirm-label="Void transaksi" :busy="busy" @confirm="confirmVoidSale" />
    <HeldSalesDialog v-model:visible="heldVisible" :sales="sales.held" :busy="busy"
      :can-resume="!sales.sale || sales.activeItems.length === 0" @resume="resume" />
    <ReceiptDialog v-model:visible="receiptVisible" :sale-id="s?.id ?? null" />
  </div>
</template>
