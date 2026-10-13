<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Select from 'primevue/select'
import MultiSelect from 'primevue/multiselect'
import ToggleSwitch from 'primevue/toggleswitch'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import OptionGroupsDialog from './OptionGroupsDialog.vue'
import { fileToProductPhoto } from '@/utils/brand'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { CatalogCategory, CatalogProduct, OptionGroupAdmin, TaxRate } from '@/types/api'
import { formatRupiah } from '@/utils/money'

const session = useSessionStore()
const { busy, run } = useApiAction()

const products = ref<CatalogProduct[]>([])
const categories = ref<CatalogCategory[]>([])
const taxes = ref<TaxRate[]>([])
const groups = ref<OptionGroupAdmin[]>([])
const loading = ref(false)
const filter = reactive({ q: '', categoryId: null as string | null, active: true as boolean | null })
// Outlet untuk tampilan & pengaturan stok (admin tanpa terminal memilih sendiri)
const stockOutletId = ref<string | null>(session.outletId ?? session.outlets[0]?.id ?? null)
const stockOutletName = computed(() => session.outlets.find((o) => o.id === stockOutletId.value)?.name ?? 'pilih outlet')

const canManage = computed(() => session.can('product.manage', 'org'))
const catOptions = computed(() => [{ name: 'Semua kategori', id: null as string | null }, ...categories.value.filter((c) => c.active)])
const taxOptions = computed(() => [{ label: 'Tanpa pajak', value: null as string | null }, ...taxes.value.filter((t) => t.active).map((t) => ({ label: `${t.name} (${t.rate}%)`, value: t.id as string | null }))])

async function loadRefs() {
  await run(async () => {
    categories.value = (await api().get<CatalogCategory[]>('/api/catalog/categories')).data
    taxes.value = (await api().get<TaxRate[]>('/api/catalog/tax-rates')).data
    groups.value = (await api().get<OptionGroupAdmin[]>('/api/catalog/option-groups')).data
  })
}

async function load() {
  loading.value = true
  await run(async () => {
    products.value = (await api().get<CatalogProduct[]>('/api/catalog/products', {
      query: { q: filter.q || undefined, categoryId: filter.categoryId ?? undefined, includeInactive: filter.active !== true, outletId: stockOutletId.value ?? undefined },
    })).data
    if (filter.active === false) products.value = products.value.filter((p) => !p.active)
  })
  loading.value = false
}
let timer: number | undefined
watch(() => [filter.categoryId, filter.active, stockOutletId.value], load)
watch(() => filter.q, () => { window.clearTimeout(timer); timer = window.setTimeout(load, 300) })
onMounted(async () => { await loadRefs(); await load() })

const stockText = (p: CatalogProduct) => (!p.trackStock ? 'Tanpa stok' : p.available === null || p.available === undefined ? '—' : Number(p.available).toLocaleString('id-ID'))
const editable = (p: CatalogProduct) => canManage.value && p.source !== 'OPENBRAVO'

// ---------------------------------------------------------------- form
const open = ref(false)
const optionsOpen = ref(false)
const editing = ref<CatalogProduct | null>(null)
const form = reactive({
  sku: '', name: '', categoryId: null as string | null, uom: 'PCS', price: null as number | null, taxRateId: null as string | null,
  barcode: '', trackStock: true, allowDecimalQty: false, active: true, groupIds: [] as string[], stock: null as number | null,
  photo: null as string | null, photoChanged: false,
})
const error = ref('')
async function pickPhoto(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  try {
    form.photo = await fileToProductPhoto(file)
    form.photoChanged = true
    error.value = ''
  } catch (err) {
    error.value = (err as Error).message
  }
  input.value = ''
}
function removePhoto() { form.photo = null; form.photoChanged = true }

function openDialog(p?: CatalogProduct) {
  editing.value = p ?? null
  Object.assign(form, {
    sku: p?.sku ?? '', name: p?.name ?? '', categoryId: p?.categoryId ?? null, uom: p?.uom ?? 'PCS',
    price: p?.price !== undefined && p?.price !== null ? Number(p.price) : null, taxRateId: p?.taxRateId ?? null,
    barcode: p?.barcode ?? '', trackStock: p?.trackStock ?? true, allowDecimalQty: p?.allowDecimalQty ?? false,
    active: p?.active ?? true, groupIds: p ? [...p.optionGroupIds] : [],
    stock: p?.available !== undefined && p?.available !== null ? Number(p.available) : null,
    photo: p?.imageUrl ?? null, photoChanged: false,
  })
  error.value = ''
  open.value = true
}

async function save() {
  error.value = ''
  if (!form.sku.trim() || !form.name.trim()) { error.value = 'SKU dan nama wajib diisi'; return }
  if (!editing.value && form.price === null) { error.value = 'Harga wajib diisi'; return }
  const body = {
    sku: form.sku.trim(), name: form.name.trim(), categoryId: form.categoryId, uom: form.uom.trim() || 'PCS',
    allowDecimalQty: form.allowDecimalQty, taxRateId: form.taxRateId, trackStock: form.trackStock, active: form.active,
    barcode: form.barcode.trim(), price: form.price,
    imageUrl: form.photoChanged ? (form.photo ?? '') : null,
  }
  const saved = await run(async () => {
    const res = editing.value
      ? await api().put<CatalogProduct>(`/api/catalog/products/${editing.value.id}`, body)
      : await api().post<CatalogProduct>('/api/catalog/products', body)
    const id = res.data.id
    await api().put(`/api/catalog/products/${id}/options`, { groupIds: form.groupIds })
    if (form.trackStock && form.stock !== null && stockOutletId.value && (!editing.value || Number(editing.value.available ?? -1) !== form.stock)) {
      await api().put(`/api/catalog/products/${id}/stock`, { outletId: stockOutletId.value, quantity: form.stock })
    }
    return res.data
  }, 'Produk disimpan')
  if (saved) { open.value = false; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Product List" :description="canManage ? 'Daftar produk, harga, stok, dan pilihan (mis. level pedas). Produk dari Openbravo hanya bisa dilihat.' : 'Daftar produk dan stok outlet ini.'">
      <template #actions>
        <Button v-if="canManage" label="Opsi produk" icon="pi pi-sliders-h" severity="secondary" @click="optionsOpen = true" />
        <Button v-if="canManage" label="Tambah produk" icon="pi pi-plus" @click="openDialog()" />
      </template>
    </PageHeader>

    <div class="mb-4 flex flex-wrap gap-3">
      <IconField class="min-w-64 flex-1">
        <InputIcon class="pi pi-search" />
        <InputText v-model="filter.q" placeholder="Cari nama, SKU, atau barcode" class="w-full" aria-label="Cari produk" />
      </IconField>
      <Select v-model="filter.categoryId" :options="catOptions" option-label="name" option-value="id" placeholder="Semua kategori" class="min-w-48" aria-label="Filter kategori" />
      <Select v-if="session.outlets.length > 1" v-model="stockOutletId" :options="session.outlets" option-label="name" option-value="id" class="min-w-48" aria-label="Outlet untuk stok" />
      <Select v-model="filter.active" :options="[{ l: 'Aktif', v: true }, { l: 'Nonaktif', v: false }, { l: 'Semua status', v: null }]" option-label="l" option-value="v" class="min-w-40" aria-label="Filter status" />
    </div>

    <DataTable :value="products" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface" paginator :rows="25">
      <template #empty>{{ canManage ? 'Belum ada produk. Klik “Tambah produk” untuk memulai.' : 'Tidak ada produk.' }}</template>
      <Column header="Produk">
        <template #body="{ data }">
          <div class="flex items-center gap-2">
            <img v-if="data.imageUrl" :src="data.imageUrl" :alt="data.name" class="h-9 w-9 rounded object-contain" />
            <div><div class="font-semibold">{{ data.name }}</div>
          <div class="tabular text-xs text-ink-soft">{{ data.sku }}<template v-if="data.barcode"> · {{ data.barcode }}</template></div></div>
          </div>
        </template>
      </Column>
      <Column header="Kategori"><template #body="{ data }">{{ data.categoryName ?? '—' }}</template></Column>
      <Column header="Harga"><template #body="{ data }"><span class="tabular">{{ data.price != null ? formatRupiah(data.price) : '—' }}</span></template></Column>
      <Column header="Stok"><template #body="{ data }"><span class="tabular text-sm">{{ stockText(data) }}</span></template></Column>
      <Column header="Pajak"><template #body="{ data }"><span class="text-sm">{{ data.taxName ?? '—' }}</span></template></Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column class="w-16"><template #body="{ data }">
        <Button v-if="editable(data)" icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.name}`" @click="openDialog(data)" />
        <i v-else-if="data.source === 'OPENBRAVO'" class="pi pi-lock text-ink-faint" title="Dikelola di Openbravo" aria-label="Dikelola di Openbravo" />
      </template></Column>
    </DataTable>

    <OptionGroupsDialog v-model:visible="optionsOpen" @changed="loadRefs" />

    <Dialog v-model:visible="open" :header="editing ? `Ubah ${editing.name}` : 'Tambah produk'" modal class="w-full max-w-2xl">
      <form class="grid gap-4 sm:grid-cols-2" novalidate @submit.prevent="save">
        <FormField label="Nama produk" for="p-name" required class="sm:col-span-2"><InputText id="p-name" v-model="form.name" class="w-full" maxlength="120" /></FormField>
        <div class="flex items-center gap-3 sm:col-span-2">
          <img v-if="form.photo" :src="form.photo" alt="Foto produk" class="h-20 w-20 rounded border border-line object-contain" />
          <div v-else class="grid h-20 w-20 place-items-center rounded border border-dashed border-line text-xs text-ink-faint">Tanpa foto</div>
          <div class="flex flex-col gap-1">
            <label class="cursor-pointer text-sm font-medium text-jade-700 underline">
              {{ form.photo ? 'Ganti foto' : 'Unggah foto' }}
              <input type="file" accept="image/png,image/jpeg,image/webp" class="sr-only" @change="pickPhoto" />
            </label>
            <button v-if="form.photo" type="button" class="text-left text-sm text-alert-600 underline" @click="removePhoto">Hapus foto</button>
            <span class="text-xs text-ink-faint">Otomatis dikecilkan. Muncul di layar kasir.</span>
          </div>
        </div>
        <FormField label="SKU" for="p-sku" required><InputText id="p-sku" v-model="form.sku" class="w-full uppercase" maxlength="40" /></FormField>
        <FormField label="Barcode" for="p-bc" hint="Kosongkan bila tidak ada"><InputText id="p-bc" v-model="form.barcode" class="w-full" maxlength="64" /></FormField>
        <FormField label="Kategori" for="p-cat">
          <Select v-model="form.categoryId" input-id="p-cat" :options="[{ name: 'Tanpa kategori', id: null as string | null }, ...categories.filter((c) => c.active)]" option-label="name" option-value="id" placeholder="Tanpa kategori" class="w-full" />
        </FormField>
        <FormField label="Satuan" for="p-uom"><InputText id="p-uom" v-model="form.uom" class="w-full" maxlength="12" placeholder="PCS, PORSI, KG" /></FormField>
        <FormField label="Harga jual (Rp)" for="p-price" required>
          <InputNumber v-model="form.price" input-id="p-price" prefix="Rp " :min="0" locale="id-ID" class="w-full" />
        </FormField>
        <FormField label="Pajak" for="p-tax"><Select v-model="form.taxRateId" input-id="p-tax" :options="taxOptions" option-label="label" option-value="value" placeholder="Tanpa pajak" class="w-full" /></FormField>
        <FormField label="Pilihan produk (opsional)" for="p-opt" class="sm:col-span-2" hint="Mis. Level pedas, Topping. Kelola grup lewat tombol “Opsi produk”.">
          <MultiSelect v-model="form.groupIds" input-id="p-opt" :options="groups.filter((g) => g.active)" option-label="name" option-value="id" placeholder="Tanpa pilihan" display="chip" class="w-full" />
        </FormField>
        <div class="flex items-center gap-3"><ToggleSwitch v-model="form.trackStock" input-id="p-track" /><label for="p-track" class="text-sm">Lacak stok <span class="text-ink-faint">(matikan untuk makanan/minuman & jasa)</span></label></div>
        <div class="flex items-center gap-3"><ToggleSwitch v-model="form.allowDecimalQty" input-id="p-dec" /><label for="p-dec" class="text-sm">Boleh jumlah desimal (kg, liter)</label></div>
        <FormField v-if="form.trackStock" :label="`Stok di ${stockOutletName}`" for="p-stock" class="sm:col-span-2" hint="Mengatur stok tersedia sekarang. Penjualan akan mengurangi stok ini.">
          <InputNumber v-model="form.stock" input-id="p-stock" :min="0" :max-fraction-digits="3" locale="id-ID" class="w-full" :disabled="!stockOutletId" />
        </FormField>
        <div v-if="editing" class="flex items-center gap-3 sm:col-span-2"><ToggleSwitch v-model="form.active" input-id="p-active" /><label for="p-active" class="text-sm">Produk aktif (dijual)</label></div>
        <p v-if="error" class="text-sm text-alert-600 sm:col-span-2" role="alert">{{ error }}</p>
        <div class="flex justify-end gap-2 pt-2 sm:col-span-2">
          <Button label="Batal" severity="secondary" text type="button" @click="open = false" />
          <Button :label="editing ? 'Simpan perubahan' : 'Simpan produk'" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
