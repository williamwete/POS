<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import ToggleSwitch from 'primevue/toggleswitch'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { DiscountPreset } from '@/types/api'
import { formatRupiah } from '@/utils/money'

const session = useSessionStore()
const { busy, run } = useApiAction()
const ALL = '__all__'
const presets = ref<DiscountPreset[]>([])

// Cakupan yang boleh dikelola user ini: seluruh outlet (hak org) dan/atau outlet tertentu.
const scopeOptions = computed(() => {
  const opts = session.outlets.filter((o) => session.can('discount.manage', o.id)).map((o) => ({ label: `${o.code} ${o.name}`, value: o.id as string }))
  if (session.can('discount.manage', 'org')) opts.unshift({ label: 'Semua outlet', value: ALL })
  return opts
})
const canManage = computed(() => scopeOptions.value.length > 0)
const outletName = (id?: string | null) => (id ? session.outlets.find((o) => o.id === id)?.name ?? 'Outlet' : 'Semua outlet')
const canEdit = (p: DiscountPreset) => (p.outletId ? session.can('discount.manage', p.outletId) : session.can('discount.manage', 'org'))

async function load() {
  await run(async () => { presets.value = (await api().get<DiscountPreset[]>('/api/discount-presets', { query: { includeInactive: true } })).data })
}
onMounted(load)

const open = ref(false)
const editing = ref<DiscountPreset | null>(null)
const form = reactive({ name: '', discountType: 'PERCENTAGE' as 'PERCENTAGE' | 'AMOUNT', discountValue: null as number | null, outletId: ALL as string, active: true })
function openDialog(p?: DiscountPreset) {
  editing.value = p ?? null
  Object.assign(form, {
    name: p?.name ?? '', discountType: p?.discountType ?? 'PERCENTAGE', discountValue: p ? Number(p.discountValue) : null,
    outletId: p ? p.outletId ?? ALL : scopeOptions.value[0]?.value ?? ALL, active: p?.active ?? true,
  })
  open.value = true
}
async function save() {
  if (form.name.trim().length < 3 || !form.discountValue || form.discountValue <= 0) return
  const body = { outletId: form.outletId === ALL ? null : form.outletId, name: form.name.trim(), discountType: form.discountType, discountValue: form.discountValue, active: form.active }
  const ok = await run(() => editing.value ? api().put(`/api/discount-presets/${editing.value.id}`, body) : api().post('/api/discount-presets', body), 'Diskon disimpan')
  if (ok) { open.value = false; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Manage Discount" description="Daftar diskon siap pakai yang muncul sebagai tombol di kasir. Batas diskon dan persetujuan supervisor tetap mengikuti pengaturan outlet.">
      <template #actions><Button v-if="canManage" label="Tambah diskon" icon="pi pi-plus" @click="openDialog()" /></template>
    </PageHeader>
    <DataTable :value="presets" data-key="id" class="rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada diskon. Kasir tetap bisa memberi diskon manual dengan alasan.</template>
      <Column field="name" header="Nama" />
      <Column header="Nilai"><template #body="{ data }"><span class="tabular">{{ data.discountType === 'PERCENTAGE' ? `${Number(data.discountValue)}%` : formatRupiah(data.discountValue) }}</span></template></Column>
      <Column header="Berlaku di"><template #body="{ data }">{{ outletName(data.outletId) }}</template></Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column class="w-16"><template #body="{ data }"><Button v-if="canEdit(data)" icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.name}`" @click="openDialog(data)" /></template></Column>
    </DataTable>

    <Dialog v-model:visible="open" :header="editing ? 'Ubah diskon' : 'Tambah diskon'" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="save">
        <FormField label="Nama diskon" for="d-name" required hint="Dipakai sebagai alasan diskon di transaksi"><InputText id="d-name" v-model="form.name" class="w-full" maxlength="60" /></FormField>
        <SelectButton v-model="form.discountType" :options="[{ l: 'Persen', v: 'PERCENTAGE' }, { l: 'Rupiah', v: 'AMOUNT' }]" option-label="l" option-value="v" :allow-empty="false" aria-label="Jenis diskon" />
        <FormField label="Nilai" for="d-value" required>
          <InputNumber v-model="form.discountValue" input-id="d-value" class="w-full" :min="0" :max="form.discountType === 'PERCENTAGE' ? 100 : undefined"
            :suffix="form.discountType === 'PERCENTAGE' ? ' %' : undefined" :prefix="form.discountType === 'AMOUNT' ? 'Rp ' : undefined" :max-fraction-digits="form.discountType === 'PERCENTAGE' ? 2 : 0" locale="id-ID" />
        </FormField>
        <FormField v-if="!editing" label="Berlaku di" for="d-scope"><Select v-model="form.outletId" input-id="d-scope" :options="scopeOptions" option-label="label" option-value="value" class="w-full" /></FormField>
        <div v-if="editing" class="flex items-center gap-3"><ToggleSwitch v-model="form.active" input-id="d-active" /><label for="d-active" class="text-sm">Diskon aktif</label></div>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="open = false" /><Button label="Simpan" type="submit" :loading="busy" /></div>
      </form>
    </Dialog>
  </div>
</template>
