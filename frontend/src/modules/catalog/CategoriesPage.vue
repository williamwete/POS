<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import ToggleSwitch from 'primevue/toggleswitch'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { CatalogCategory, TaxRate } from '@/types/api'

const session = useSessionStore()
const { busy, run } = useApiAction()
const categories = ref<CatalogCategory[]>([])
const taxes = ref<TaxRate[]>([])
const canCategory = computed(() => session.can('category.manage', 'org'))
const canTax = computed(() => session.can('product.manage', 'org'))

async function load() {
  await run(async () => {
    categories.value = (await api().get<CatalogCategory[]>('/api/catalog/categories')).data
    taxes.value = (await api().get<TaxRate[]>('/api/catalog/tax-rates')).data
  })
}
onMounted(load)

// ---------------------------------------------------------------- kategori
const catOpen = ref(false)
const catEditing = ref<CatalogCategory | null>(null)
const cat = reactive({ code: '', name: '', active: true })
function openCat(c?: CatalogCategory) {
  catEditing.value = c ?? null
  Object.assign(cat, { code: c?.code ?? '', name: c?.name ?? '', active: c?.active ?? true })
  catOpen.value = true
}
async function saveCat() {
  if (!cat.code.trim() || !cat.name.trim()) return
  const body = { code: cat.code.trim().toUpperCase(), name: cat.name.trim(), active: cat.active }
  const ok = await run(() => catEditing.value
    ? api().put(`/api/catalog/categories/${catEditing.value.id}`, body)
    : api().post('/api/catalog/categories', body), 'Kategori disimpan')
  if (ok) { catOpen.value = false; await load() }
}

// ---------------------------------------------------------------- pajak
const taxOpen = ref(false)
const taxEditing = ref<TaxRate | null>(null)
const tax = reactive({ code: '', name: '', rate: 11 as number | null, active: true })
function openTax(t?: TaxRate) {
  taxEditing.value = t ?? null
  Object.assign(tax, { code: t?.code ?? '', name: t?.name ?? '', rate: t ? Number(t.rate) : 11, active: t?.active ?? true })
  taxOpen.value = true
}
async function saveTax() {
  if (!tax.code.trim() || !tax.name.trim() || tax.rate === null) return
  const body = { code: tax.code.trim().toUpperCase(), name: tax.name.trim(), rate: tax.rate, active: tax.active }
  const ok = await run(() => taxEditing.value
    ? api().put(`/api/catalog/tax-rates/${taxEditing.value.id}`, body)
    : api().post('/api/catalog/tax-rates', body), 'Pajak disimpan')
  if (ok) { taxOpen.value = false; await load() }
}
</script>

<template>
  <div class="space-y-10">
    <section>
      <PageHeader title="Manage Categories" description="Kategori mengelompokkan produk di katalog kasir.">
        <template #actions><Button v-if="canCategory" label="Tambah kategori" icon="pi pi-plus" @click="openCat()" /></template>
      </PageHeader>
      <DataTable :value="categories" data-key="id" class="rounded-2xl border border-line bg-surface">
        <template #empty>Belum ada kategori.</template>
        <Column header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.code }}</span></template></Column>
        <Column field="name" header="Nama" />
        <Column header="Produk aktif"><template #body="{ data }"><span class="tabular">{{ data.productCount }}</span></template></Column>
        <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
        <Column class="w-16"><template #body="{ data }">
          <Button v-if="canCategory && data.source !== 'OPENBRAVO'" icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.name}`" @click="openCat(data)" />
          <i v-else-if="data.source === 'OPENBRAVO'" class="pi pi-lock text-ink-faint" aria-label="Dikelola di Openbravo" />
        </template></Column>
      </DataTable>
    </section>

    <section>
      <PageHeader title="Pajak" description="Tarif yang bisa dipasang ke produk. Gunakan PPN 11% hanya bila usaha Anda PKP; restoran umumnya memakai PB1 (sekitar 10%, sesuai perda).">
        <template #actions><Button v-if="canTax" label="Tambah pajak" icon="pi pi-plus" severity="secondary" @click="openTax()" /></template>
      </PageHeader>
      <DataTable :value="taxes" data-key="id" class="rounded-2xl border border-line bg-surface">
        <template #empty>Belum ada tarif pajak. Produk tanpa pajak dijual tanpa pajak.</template>
        <Column header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.code }}</span></template></Column>
        <Column field="name" header="Nama" />
        <Column header="Tarif"><template #body="{ data }"><span class="tabular">{{ Number(data.rate) }}%</span></template></Column>
        <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
        <Column class="w-16"><template #body="{ data }">
          <Button v-if="canTax && data.source !== 'OPENBRAVO'" icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.name}`" @click="openTax(data)" />
        </template></Column>
      </DataTable>
    </section>

    <Dialog v-model:visible="catOpen" :header="catEditing ? 'Ubah kategori' : 'Tambah kategori'" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="saveCat">
        <FormField label="Kode" for="c-code" required><InputText id="c-code" v-model="cat.code" class="w-full uppercase" maxlength="30" /></FormField>
        <FormField label="Nama" for="c-name" required><InputText id="c-name" v-model="cat.name" class="w-full" maxlength="60" /></FormField>
        <div v-if="catEditing" class="flex items-center gap-3"><ToggleSwitch v-model="cat.active" input-id="c-active" /><label for="c-active" class="text-sm">Kategori aktif</label></div>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="catOpen = false" /><Button label="Simpan" type="submit" :loading="busy" /></div>
      </form>
    </Dialog>

    <Dialog v-model:visible="taxOpen" :header="taxEditing ? 'Ubah pajak' : 'Tambah pajak'" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="saveTax">
        <FormField label="Kode" for="t-code" required><InputText id="t-code" v-model="tax.code" class="w-full uppercase" maxlength="30" placeholder="PPN11" /></FormField>
        <FormField label="Nama" for="t-name" required><InputText id="t-name" v-model="tax.name" class="w-full" maxlength="60" placeholder="PPN 11%" /></FormField>
        <FormField label="Tarif (%)" for="t-rate" required><InputNumber v-model="tax.rate" input-id="t-rate" :min="0" :max="100" :max-fraction-digits="3" suffix=" %" class="w-full" /></FormField>
        <div v-if="taxEditing" class="flex items-center gap-3"><ToggleSwitch v-model="tax.active" input-id="t-active" /><label for="t-active" class="text-sm">Pajak aktif</label></div>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="taxOpen = false" /><Button label="Simpan" type="submit" :loading="busy" /></div>
      </form>
    </Dialog>
  </div>
</template>
