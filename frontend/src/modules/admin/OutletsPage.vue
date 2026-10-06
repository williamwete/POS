<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import ToggleSwitch from 'primevue/toggleswitch'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Outlet, Warehouse } from '@/types/api'
import { fieldErrorsOf, outletCreateSchema } from '@/utils/validation'

const session = useSessionStore()
const outlets = ref<Outlet[]>([])
const loading = ref(false)
const { busy, run } = useApiAction()

const TIMEZONES = [
  { label: 'Ikuti organisasi', value: '' },
  { label: 'WIB (Asia/Jakarta)', value: 'Asia/Jakarta' },
  { label: 'WITA (Asia/Makassar)', value: 'Asia/Makassar' },
  { label: 'WIT (Asia/Jayapura)', value: 'Asia/Jayapura' },
]

async function load() {
  loading.value = true
  await run(async () => {
    outlets.value = (await api().get<Outlet[]>('/api/outlets')).data
  })
  loading.value = false
}
onMounted(load)

// ---------------------------------------------------------------- create
const createOpen = ref(false)
const createForm = reactive({ code: '', name: '', address: '', phone: '', timezone: '' })
const createErrors = ref<Record<string, string>>({})

function openCreate() {
  Object.assign(createForm, { code: '', name: '', address: '', phone: '', timezone: '' })
  createErrors.value = {}
  createOpen.value = true
}

async function submitCreate() {
  const parsed = outletCreateSchema.safeParse(createForm)
  createErrors.value = fieldErrorsOf(parsed)
  if (!parsed.success) return
  const ok = await run(
    (key) => api().post<Outlet>('/api/outlets', {
      code: parsed.data.code,
      name: parsed.data.name,
      address: parsed.data.address || null,
      phone: parsed.data.phone || null,
      timezone: parsed.data.timezone || null,
    }, { idempotencyKey: key }),
    'Outlet dibuat',
  )
  if (ok) {
    createOpen.value = false
    await Promise.all([load(), session.refresh()])
  }
}

// ---------------------------------------------------------------- edit
const editOpen = ref(false)
const editing = ref<Outlet | null>(null)
const editForm = reactive({ name: '', address: '', phone: '', timezone: '', defaultWarehouseId: null as string | null, active: true })
const warehouses = ref<Warehouse[]>([])
const warehouseOptions = computed(() => [{ label: 'Tidak ada', value: null }, ...warehouses.value.map((w) => ({ label: `${w.code} ${w.name}`, value: w.id }))])

async function openEdit(o: Outlet) {
  editing.value = o
  Object.assign(editForm, {
    name: o.name, address: o.address ?? '', phone: o.phone ?? '', timezone: o.timezone ?? '',
    defaultWarehouseId: o.defaultWarehouseId ?? null, active: o.active,
  })
  editOpen.value = true
  warehouses.value = (await api().get<Warehouse[]>('/api/warehouses', { query: { outletId: o.id } })).data
}

async function submitEdit() {
  if (!editing.value) return
  const ok = await run(
    () => api().put<Outlet>(`/api/outlets/${editing.value!.id}`, {
      name: editForm.name.trim(),
      address: editForm.address || null,
      phone: editForm.phone || null,
      timezone: editForm.timezone || null,
      defaultWarehouseId: editForm.defaultWarehouseId,
      active: editForm.active,
      version: editing.value!.version,
    }),
    'Outlet diperbarui',
  )
  if (ok) {
    editOpen.value = false
    await Promise.all([load(), session.refresh()])
  }
}
</script>

<template>
  <div>
    <PageHeader title="Outlet" description="Daftar toko. Outlet dinonaktifkan, tidak dihapus, agar riwayat transaksinya tetap utuh.">
      <template #actions>
        <Button label="Tambah outlet" icon="pi pi-plus" @click="openCreate" />
      </template>
    </PageHeader>

    <DataTable :value="outlets" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface" striped-rows>
      <template #empty>Belum ada outlet. Tambahkan outlet pertama Anda.</template>
      <Column field="code" header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.code }}</span></template></Column>
      <Column field="name" header="Nama" />
      <Column field="address" header="Alamat"><template #body="{ data }"><span class="text-sm text-ink-soft">{{ data.address ?? '—' }}</span></template></Column>
      <Column header="Timezone"><template #body="{ data }"><span class="text-sm">{{ data.timezone ?? 'Organisasi' }}</span></template></Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column header="" class="w-16">
        <template #body="{ data }">
          <Button icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.name}`" @click="openEdit(data)" />
        </template>
      </Column>
    </DataTable>

    <Dialog v-model:visible="createOpen" header="Tambah outlet" modal class="w-full max-w-lg">
      <form class="space-y-4" novalidate @submit.prevent="submitCreate">
        <FormField label="Kode outlet" for="o-code" :error="createErrors.code" hint="Contoh: JKT02. Tidak dapat diubah." required>
          <InputText id="o-code" v-model="createForm.code" class="w-full uppercase" @input="createForm.code = createForm.code.toUpperCase()" />
        </FormField>
        <FormField label="Nama" for="o-name" :error="createErrors.name" required>
          <InputText id="o-name" v-model="createForm.name" class="w-full" />
        </FormField>
        <FormField label="Alamat" for="o-address"><InputText id="o-address" v-model="createForm.address" class="w-full" /></FormField>
        <FormField label="Telepon" for="o-phone"><InputText id="o-phone" v-model="createForm.phone" class="w-full" /></FormField>
        <FormField label="Timezone" for="o-tz">
          <Select v-model="createForm.timezone" input-id="o-tz" :options="TIMEZONES" option-label="label" option-value="value" class="w-full" />
        </FormField>
        <div class="flex justify-end gap-2 pt-2">
          <Button label="Batal" severity="secondary" text type="button" @click="createOpen = false" />
          <Button label="Simpan outlet" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>

    <Dialog v-model:visible="editOpen" :header="`Ubah ${editing?.code ?? ''}`" modal class="w-full max-w-lg">
      <form class="space-y-4" novalidate @submit.prevent="submitEdit">
        <FormField label="Nama" for="e-name" required><InputText id="e-name" v-model="editForm.name" class="w-full" /></FormField>
        <FormField label="Alamat" for="e-address"><InputText id="e-address" v-model="editForm.address" class="w-full" /></FormField>
        <FormField label="Telepon" for="e-phone"><InputText id="e-phone" v-model="editForm.phone" class="w-full" /></FormField>
        <FormField label="Timezone" for="e-tz">
          <Select v-model="editForm.timezone" input-id="e-tz" :options="TIMEZONES" option-label="label" option-value="value" class="w-full" />
        </FormField>
        <FormField label="Warehouse utama" for="e-wh" hint="Dipakai untuk mapping stok Openbravo.">
          <Select v-model="editForm.defaultWarehouseId" input-id="e-wh" :options="warehouseOptions" option-label="label" option-value="value" placeholder="Tidak ada" class="w-full" />
        </FormField>
        <div class="flex items-center gap-3">
          <ToggleSwitch v-model="editForm.active" input-id="e-active" />
          <label for="e-active" class="text-sm">Outlet aktif</label>
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <Button label="Batal" severity="secondary" text type="button" @click="editOpen = false" />
          <Button label="Simpan perubahan" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
