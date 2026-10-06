<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import ToggleSwitch from 'primevue/toggleswitch'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Device, DeviceType, Terminal } from '@/types/api'
import { deviceSchema, fieldErrorsOf, terminalSchema } from '@/utils/validation'

const session = useSessionStore()
const { busy, run } = useApiAction()

// Outlet yang boleh dikelola terminalnya (UX; backend memvalidasi ulang)
const manageableOutlets = computed(() => session.outlets.filter((o) => session.can('terminal.manage', o.id)))
const outletId = ref<string | null>(
  manageableOutlets.value.find((o) => o.id === session.outletId)?.id ?? manageableOutlets.value[0]?.id ?? null,
)
const tab = ref('terminals')

const terminals = ref<Terminal[]>([])
const devices = ref<Device[]>([])
const loading = ref(false)

const DEVICE_TYPES: { label: string; value: DeviceType }[] = [
  { label: 'Printer struk', value: 'PRINTER' },
  { label: 'Laci kas', value: 'CASH_DRAWER' },
  { label: 'Browser / PC kasir', value: 'BROWSER' },
  { label: 'Scanner barcode', value: 'SCANNER' },
  { label: 'Layar pelanggan', value: 'CUSTOMER_DISPLAY' },
]
const typeLabel = (t: DeviceType) => DEVICE_TYPES.find((d) => d.value === t)?.label ?? t

function deviceOptions(type: DeviceType) {
  return [
    { label: 'Tidak ada', value: null },
    ...devices.value.filter((d) => d.deviceType === type && d.active).map((d) => ({ label: `${d.code} ${d.name}`, value: d.id })),
  ]
}

async function load() {
  if (!outletId.value) return
  loading.value = true
  await run(async () => {
    const [t, d] = await Promise.all([
      api().get<Terminal[]>('/api/terminals', { query: { outletId: outletId.value } }),
      api().get<Device[]>('/api/devices', { query: { outletId: outletId.value } }),
    ])
    terminals.value = t.data
    devices.value = d.data
  })
  loading.value = false
}
watch(outletId, load)
onMounted(load)

// ---------------------------------------------------------------- terminal dialog
const tOpen = ref(false)
const tEditing = ref<Terminal | null>(null)
const tForm = reactive({ code: '', name: '', printerId: null as string | null, cashDrawerId: null as string | null, deviceId: null as string | null, active: true })
const tErrors = ref<Record<string, string>>({})

function openTerminal(t?: Terminal) {
  tEditing.value = t ?? null
  Object.assign(tForm, {
    code: t?.code ?? '', name: t?.name ?? '', printerId: t?.printerId ?? null,
    cashDrawerId: t?.cashDrawerId ?? null, deviceId: t?.deviceId ?? null, active: t?.active ?? true,
  })
  tErrors.value = {}
  tOpen.value = true
}

async function saveTerminal() {
  if (!outletId.value) return
  let ok: unknown
  if (tEditing.value) {
    if (!tForm.name.trim()) { tErrors.value = { name: 'Nama wajib diisi' }; return }
    ok = await run(() => api().put(`/api/terminals/${tEditing.value!.id}`, {
      name: tForm.name.trim(), printerId: tForm.printerId, cashDrawerId: tForm.cashDrawerId,
      deviceId: tForm.deviceId, active: tForm.active, version: tEditing.value!.version,
    }), 'Terminal diperbarui')
  } else {
    const parsed = terminalSchema.safeParse({ outletId: outletId.value, code: tForm.code, name: tForm.name })
    tErrors.value = fieldErrorsOf(parsed)
    if (!parsed.success) return
    ok = await run((key) => api().post('/api/terminals', {
      ...parsed.data, printerId: tForm.printerId, cashDrawerId: tForm.cashDrawerId, deviceId: tForm.deviceId,
    }, { idempotencyKey: key }), 'Terminal dibuat')
  }
  if (ok) { tOpen.value = false; await load() }
}

// ---------------------------------------------------------------- device dialog
const dOpen = ref(false)
const dEditing = ref<Device | null>(null)
const dForm = reactive({ deviceType: 'PRINTER' as DeviceType, code: '', name: '', identifier: '', active: true })
const dErrors = ref<Record<string, string>>({})

function openDevice(d?: Device) {
  dEditing.value = d ?? null
  Object.assign(dForm, {
    deviceType: d?.deviceType ?? 'PRINTER', code: d?.code ?? '', name: d?.name ?? '',
    identifier: d?.identifier ?? '', active: d?.active ?? true,
  })
  dErrors.value = {}
  dOpen.value = true
}

async function saveDevice() {
  if (!outletId.value) return
  let ok: unknown
  if (dEditing.value) {
    if (!dForm.name.trim()) { dErrors.value = { name: 'Nama wajib diisi' }; return }
    ok = await run(() => api().put(`/api/devices/${dEditing.value!.id}`, {
      name: dForm.name.trim(), identifier: dForm.identifier || null, active: dForm.active, version: dEditing.value!.version,
    }), 'Device diperbarui')
  } else {
    const parsed = deviceSchema.safeParse({ outletId: outletId.value, ...dForm })
    dErrors.value = fieldErrorsOf(parsed)
    if (!parsed.success) return
    ok = await run((key) => api().post('/api/devices', {
      outletId: parsed.data.outletId, deviceType: parsed.data.deviceType, code: parsed.data.code,
      name: parsed.data.name, identifier: parsed.data.identifier || null,
    }, { idempotencyKey: key }), 'Device dibuat')
  }
  if (ok) { dOpen.value = false; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Terminal & device" description="Setiap terminal adalah satu meja kasir. Printer dan laci kas harus berada di outlet yang sama.">
      <template #actions>
        <Select
          v-model="outletId"
          :options="manageableOutlets"
          option-label="name"
          option-value="id"
          placeholder="Pilih outlet"
          class="min-w-56"
          aria-label="Outlet"
        />
      </template>
    </PageHeader>

    <p v-if="!manageableOutlets.length" class="rounded-lg border border-dashed border-line p-4 text-sm text-ink-soft">
      Anda tidak memiliki izin mengelola terminal di outlet mana pun.
    </p>

    <Tabs v-else v-model:value="tab">
      <TabList>
        <Tab value="terminals">Terminal ({{ terminals.length }})</Tab>
        <Tab value="devices">Device ({{ devices.length }})</Tab>
      </TabList>
      <TabPanels class="!px-0">
        <TabPanel value="terminals">
          <div class="mb-3 flex justify-end"><Button label="Tambah terminal" icon="pi pi-plus" @click="openTerminal()" /></div>
          <DataTable :value="terminals" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface">
            <template #empty>Belum ada terminal di outlet ini.</template>
            <Column header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.code }}</span></template></Column>
            <Column field="name" header="Nama" />
            <Column header="Printer"><template #body="{ data }">{{ data.printerName ?? '—' }}</template></Column>
            <Column header="Laci kas"><template #body="{ data }">{{ data.cashDrawerName ?? '—' }}</template></Column>
            <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
            <Column class="w-16"><template #body="{ data }"><Button icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.code}`" @click="openTerminal(data)" /></template></Column>
          </DataTable>
        </TabPanel>
        <TabPanel value="devices">
          <div class="mb-3 flex justify-end"><Button label="Tambah device" icon="pi pi-plus" @click="openDevice()" /></div>
          <DataTable :value="devices" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface">
            <template #empty>Belum ada device di outlet ini.</template>
            <Column header="Kode"><template #body="{ data }"><span class="tabular font-semibold">{{ data.code }}</span></template></Column>
            <Column field="name" header="Nama" />
            <Column header="Tipe"><template #body="{ data }">{{ typeLabel(data.deviceType) }}</template></Column>
            <Column header="Alamat / serial"><template #body="{ data }"><span class="tabular text-sm text-ink-soft">{{ data.identifier ?? '—' }}</span></template></Column>
            <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
            <Column class="w-16"><template #body="{ data }"><Button icon="pi pi-pencil" text rounded :aria-label="`Ubah ${data.code}`" @click="openDevice(data)" /></template></Column>
          </DataTable>
        </TabPanel>
      </TabPanels>
    </Tabs>

    <Dialog v-model:visible="tOpen" :header="tEditing ? `Ubah ${tEditing.code}` : 'Tambah terminal'" modal class="w-full max-w-lg">
      <form class="space-y-4" novalidate @submit.prevent="saveTerminal">
        <FormField v-if="!tEditing" label="Kode terminal" for="t-code" :error="tErrors.code" hint="Menjadi prefix nomor struk, mis. POS-JKT-03. Tidak dapat diubah." required>
          <InputText id="t-code" v-model="tForm.code" class="w-full uppercase" @input="tForm.code = tForm.code.toUpperCase()" />
        </FormField>
        <FormField label="Nama" for="t-name" :error="tErrors.name" required><InputText id="t-name" v-model="tForm.name" class="w-full" /></FormField>
        <FormField label="Printer struk" for="t-printer">
          <Select v-model="tForm.printerId" input-id="t-printer" :options="deviceOptions('PRINTER')" option-label="label" option-value="value" placeholder="Tidak ada" class="w-full" />
        </FormField>
        <FormField label="Laci kas" for="t-drawer">
          <Select v-model="tForm.cashDrawerId" input-id="t-drawer" :options="deviceOptions('CASH_DRAWER')" option-label="label" option-value="value" placeholder="Tidak ada" class="w-full" />
        </FormField>
        <FormField label="PC / browser kasir" for="t-device" hint="Opsional. Satu device hanya untuk satu terminal aktif.">
          <Select v-model="tForm.deviceId" input-id="t-device" :options="deviceOptions('BROWSER')" option-label="label" option-value="value" placeholder="Tidak ada" class="w-full" />
        </FormField>
        <div v-if="tEditing" class="flex items-center gap-3">
          <ToggleSwitch v-model="tForm.active" input-id="t-active" />
          <label for="t-active" class="text-sm">Terminal aktif</label>
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <Button label="Batal" severity="secondary" text type="button" @click="tOpen = false" />
          <Button :label="tEditing ? 'Simpan perubahan' : 'Simpan terminal'" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>

    <Dialog v-model:visible="dOpen" :header="dEditing ? `Ubah ${dEditing.code}` : 'Tambah device'" modal class="w-full max-w-lg">
      <form class="space-y-4" novalidate @submit.prevent="saveDevice">
        <FormField v-if="!dEditing" label="Tipe" for="d-type" required>
          <Select v-model="dForm.deviceType" input-id="d-type" :options="DEVICE_TYPES" option-label="label" option-value="value" class="w-full" />
        </FormField>
        <FormField v-if="!dEditing" label="Kode device" for="d-code" :error="dErrors.code" required>
          <InputText id="d-code" v-model="dForm.code" class="w-full uppercase" @input="dForm.code = dForm.code.toUpperCase()" />
        </FormField>
        <FormField label="Nama" for="d-name" :error="dErrors.name" required><InputText id="d-name" v-model="dForm.name" class="w-full" /></FormField>
        <FormField label="Alamat atau serial" for="d-id" hint="Mis. tcp://192.168.10.21:9100">
          <InputText id="d-id" v-model="dForm.identifier" class="w-full" />
        </FormField>
        <div v-if="dEditing" class="flex items-center gap-3">
          <ToggleSwitch v-model="dForm.active" input-id="d-active" />
          <label for="d-active" class="text-sm">Device aktif</label>
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <Button label="Batal" severity="secondary" text type="button" @click="dOpen = false" />
          <Button :label="dEditing ? 'Simpan perubahan' : 'Simpan device'" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
