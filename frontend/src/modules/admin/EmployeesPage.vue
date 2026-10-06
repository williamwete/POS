<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import ToggleSwitch from 'primevue/toggleswitch'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Employee } from '@/types/api'
import { employeeSchema, fieldErrorsOf } from '@/utils/validation'

const session = useSessionStore()
const { busy, run } = useApiAction()

const employees = ref<Employee[]>([])
const loading = ref(false)
const filter = reactive({ outletId: null as string | null, q: '', active: true as boolean | null })

const outletFilterOptions = computed(() => [{ name: 'Semua outlet', id: null as string | null }, ...session.outlets])
// Tujuan home outlet saat membuat/mengubah: hanya outlet tempat user boleh employee.manage
const homeOutletOptions = computed(() => {
  const opts = session.outlets.filter((o) => session.can('employee.manage', o.id)).map((o) => ({ label: `${o.code} ${o.name}`, value: o.id as string | null }))
  if (session.can('employee.manage', 'org')) opts.unshift({ label: 'Kantor pusat (tanpa outlet)', value: null })
  return opts
})
const canCreate = computed(() => homeOutletOptions.value.length > 0)

function canEdit(e: Employee) {
  return e.homeOutletId ? session.can('employee.manage', e.homeOutletId) : session.can('employee.manage', 'org')
}

let searchTimer: number | undefined
async function load() {
  loading.value = true
  await run(async () => {
    employees.value = (await api().get<Employee[]>('/api/employees', {
      query: { outletId: filter.outletId, q: filter.q || undefined, active: filter.active ?? undefined },
    })).data
  })
  loading.value = false
}
watch(() => [filter.outletId, filter.active], load)
watch(() => filter.q, () => {
  window.clearTimeout(searchTimer)
  searchTimer = window.setTimeout(load, 300)
})
onMounted(load)

// ---------------------------------------------------------------- dialog
const open = ref(false)
const editing = ref<Employee | null>(null)
const form = reactive({
  employeeCode: '', fullName: '', email: '', phone: '', position: '',
  homeOutletId: null as string | null, hireDate: null as Date | null, active: true,
})
const errors = ref<Record<string, string>>({})

function toYmd(d: Date | null): string | null {
  if (!d) return null
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

function openDialog(e?: Employee) {
  editing.value = e ?? null
  Object.assign(form, {
    employeeCode: e?.employeeCode ?? '', fullName: e?.fullName ?? '', email: e?.email ?? '',
    phone: e?.phone ?? '', position: e?.position ?? '',
    homeOutletId: e ? e.homeOutletId ?? null : homeOutletOptions.value[0]?.value ?? null,
    hireDate: e?.hireDate ? new Date(`${e.hireDate}T00:00:00`) : null, active: e?.active ?? true,
  })
  errors.value = {}
  open.value = true
}

async function save() {
  const parsed = employeeSchema.safeParse({ ...form, employeeCode: editing.value?.employeeCode ?? form.employeeCode })
  errors.value = fieldErrorsOf(parsed)
  if (!parsed.success) return
  const payload = {
    fullName: parsed.data.fullName,
    email: parsed.data.email || null,
    phone: parsed.data.phone || null,
    position: parsed.data.position || null,
    homeOutletId: form.homeOutletId,
    hireDate: toYmd(form.hireDate),
  }
  const ok = editing.value
    ? await run(() => api().put(`/api/employees/${editing.value!.id}`, { ...payload, active: form.active, version: editing.value!.version }), 'Data karyawan diperbarui')
    : await run((key) => api().post('/api/employees', { employeeCode: parsed.data.employeeCode, ...payload }, { idempotencyKey: key }), 'Karyawan dibuat')
  if (ok) { open.value = false; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Karyawan" description="Data karyawan terpisah dari akun login. Karyawan tanpa akun tetap tercatat untuk kehadiran.">
      <template #actions>
        <Button v-if="canCreate" label="Tambah karyawan" icon="pi pi-plus" @click="openDialog()" />
      </template>
    </PageHeader>

    <div class="mb-4 flex flex-wrap gap-3">
      <IconField class="min-w-64 flex-1">
        <InputIcon class="pi pi-search" />
        <InputText v-model="filter.q" placeholder="Cari nama atau kode" class="w-full" aria-label="Cari karyawan" />
      </IconField>
      <Select v-model="filter.outletId" :options="outletFilterOptions" option-label="name" option-value="id" placeholder="Semua outlet" class="min-w-48" aria-label="Filter outlet" />
      <Select
        v-model="filter.active"
        :options="[{ l: 'Aktif', v: true }, { l: 'Nonaktif', v: false }, { l: 'Semua status', v: null }]"
        option-label="l" option-value="v" placeholder="Semua status" class="min-w-40" aria-label="Filter status"
      />
    </div>

    <DataTable :value="employees" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface" paginator :rows="25">
      <template #empty>Tidak ada karyawan yang cocok dengan filter.</template>
      <Column header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.employeeCode }}</span></template></Column>
      <Column field="fullName" header="Nama" />
      <Column field="position" header="Jabatan" />
      <Column header="Outlet"><template #body="{ data }">{{ data.homeOutletCode ?? 'Kantor pusat' }}</template></Column>
      <Column header="Akun"><template #body="{ data }"><span class="text-sm">{{ data.linkedUsername ?? '—' }}</span></template></Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column class="w-16">
        <template #body="{ data }">
          <Button v-if="canEdit(data)" icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.fullName}`" @click="openDialog(data)" />
        </template>
      </Column>
    </DataTable>

    <Dialog v-model:visible="open" :header="editing ? `Ubah ${editing.employeeCode}` : 'Tambah karyawan'" modal class="w-full max-w-lg">
      <form class="grid gap-4 sm:grid-cols-2" novalidate @submit.prevent="save">
        <FormField v-if="!editing" label="Kode karyawan" for="e-code" :error="errors.employeeCode" required class="sm:col-span-2">
          <InputText id="e-code" v-model="form.employeeCode" class="w-full uppercase" @input="form.employeeCode = form.employeeCode.toUpperCase()" />
        </FormField>
        <FormField label="Nama lengkap" for="e-name" :error="errors.fullName" required class="sm:col-span-2">
          <InputText id="e-name" v-model="form.fullName" class="w-full" />
        </FormField>
        <FormField label="Jabatan" for="e-pos" :error="errors.position"><InputText id="e-pos" v-model="form.position" class="w-full" /></FormField>
        <FormField label="Tanggal masuk" for="e-hire">
          <DatePicker v-model="form.hireDate" input-id="e-hire" date-format="dd/mm/yy" show-icon class="w-full" />
        </FormField>
        <FormField label="Email" for="e-email" :error="errors.email"><InputText id="e-email" v-model="form.email" type="email" class="w-full" /></FormField>
        <FormField label="Telepon" for="e-phone" :error="errors.phone"><InputText id="e-phone" v-model="form.phone" class="w-full" /></FormField>
        <FormField label="Outlet asal" for="e-outlet" class="sm:col-span-2">
          <Select v-model="form.homeOutletId" input-id="e-outlet" :options="homeOutletOptions" option-label="label" option-value="value" placeholder="Kantor pusat (tanpa outlet)" class="w-full" />
        </FormField>
        <div v-if="editing" class="flex items-center gap-3 sm:col-span-2">
          <ToggleSwitch v-model="form.active" input-id="e-active" />
          <label for="e-active" class="text-sm">Karyawan aktif</label>
        </div>
        <div class="flex justify-end gap-2 pt-2 sm:col-span-2">
          <Button label="Batal" severity="secondary" text type="button" @click="open = false" />
          <Button :label="editing ? 'Simpan perubahan' : 'Simpan karyawan'" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
