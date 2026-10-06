<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import ToggleSwitch from 'primevue/toggleswitch'
import PageHeader from '@/components/PageHeader.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { PaymentMethod } from '@/types/api'
import { KIND_ICON } from '@/modules/pos/paymentFormat'

const methods = ref<PaymentMethod[]>([])
const loading = ref(false)
const { busy, run } = useApiAction()

const CONFIRMATION_LABEL: Record<string, string> = {
  IMMEDIATE: 'Langsung (tunai)',
  MANUAL: 'Manual dengan referensi',
  GATEWAY: 'Penyedia pembayaran',
}

async function load() {
  loading.value = true
  await run(async () => {
    methods.value = (await api().get<PaymentMethod[]>('/api/admin/payment-methods')).data
  })
  loading.value = false
}
onMounted(load)

const editing = ref<PaymentMethod | null>(null)
const form = reactive({
  name: '', active: true, requiresReference: false, requiresApproval: false, manualConfirmAllowed: false,
  sortOrder: 0, openbravoPaymentMethodId: '',
})

function edit(m: PaymentMethod) {
  editing.value = m
  Object.assign(form, {
    name: m.name, active: m.active, requiresReference: m.requiresReference, requiresApproval: m.requiresApproval,
    manualConfirmAllowed: m.manualConfirmAllowed, sortOrder: m.sortOrder, openbravoPaymentMethodId: m.openbravoPaymentMethodId ?? '',
  })
}

async function save() {
  const m = editing.value
  if (!m || !form.name.trim()) return
  const ok = await run(
    () => api().put<PaymentMethod>(`/api/admin/payment-methods/${m.id}`, {
      ...form, name: form.name.trim(), openbravoPaymentMethodId: form.openbravoPaymentMethodId.trim() || null, version: m.version,
    }),
    'Metode pembayaran disimpan',
  )
  if (ok) {
    editing.value = null
    await load()
  }
}
</script>

<template>
  <div>
    <PageHeader title="Metode pembayaran"
      description="Metode yang tampil di layar kasir dan cara konfirmasinya. Kode & jenis metode tetap; perubahan tercatat di audit log." />

    <DataTable :value="methods" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface">
      <Column header="Metode">
        <template #body="{ data }">
          <div class="flex items-center gap-2">
            <i :class="[KIND_ICON[data.kind] ?? 'pi pi-wallet', 'text-ink-soft']" aria-hidden="true" />
            <div>
              <div class="font-semibold">{{ data.name }}</div>
              <div class="tabular text-xs text-ink-soft">{{ data.code }}</div>
            </div>
          </div>
        </template>
      </Column>
      <Column header="Konfirmasi">
        <template #body="{ data }">
          <div class="text-sm">{{ CONFIRMATION_LABEL[data.confirmation] }}</div>
          <div class="text-xs text-ink-soft">
            <template v-if="data.requiresReference">wajib referensi</template>
            <template v-if="data.requiresApproval && data.confirmation === 'MANUAL'"> · approval supervisor</template>
            <template v-if="data.manualConfirmAllowed"> · boleh konfirmasi manual (dengan approval)</template>
          </div>
          <div v-if="!data.available" class="mt-1 text-xs text-amber-700">
            Penyedia pembayaran belum terhubung — aktifkan konfirmasi manual (QRIS statis) agar bisa dipakai.
          </div>
        </template>
      </Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column header="Urutan"><template #body="{ data }"><span class="tabular">{{ data.sortOrder }}</span></template></Column>
      <Column class="w-24">
        <template #body="{ data }"><Button label="Ubah" size="small" text @click="edit(data)" /></template>
      </Column>
    </DataTable>

    <Dialog :visible="!!editing" modal :header="`Ubah ${editing?.code ?? ''}`" class="w-full max-w-lg"
      @update:visible="(v) => { if (!v) editing = null }">
      <form v-if="editing" class="space-y-4" @submit.prevent="save">
        <div>
          <label for="pm-name" class="mb-1 block text-sm font-medium">Nama di layar kasir</label>
          <InputText id="pm-name" v-model="form.name" class="w-full" maxlength="60" />
        </div>
        <label class="flex items-center justify-between gap-4">
          <span class="text-sm font-medium">Aktif</span>
          <ToggleSwitch v-model="form.active" :disabled="editing.kind === 'CASH'" />
        </label>
        <label v-if="editing.confirmation !== 'IMMEDIATE'" class="flex items-center justify-between gap-4">
          <span class="text-sm">
            <span class="font-medium">Wajib nomor referensi</span>
            <span class="block text-xs text-ink-soft">Selalu wajib untuk konfirmasi manual.</span>
          </span>
          <ToggleSwitch v-model="form.requiresReference" :disabled="editing.confirmation === 'MANUAL'" />
        </label>
        <label v-if="editing.confirmation === 'MANUAL'" class="flex items-center justify-between gap-4">
          <span class="text-sm">
            <span class="font-medium">Wajib approval supervisor</span>
            <span class="block text-xs text-ink-soft">Disarankan untuk transfer bank.</span>
          </span>
          <ToggleSwitch v-model="form.requiresApproval" />
        </label>
        <label v-if="editing.confirmation === 'GATEWAY'" class="flex items-center justify-between gap-4">
          <span class="text-sm">
            <span class="font-medium">Boleh dikonfirmasi manual</span>
            <span class="block text-xs text-ink-soft">Untuk QRIS statis / saat penyedia tidak mengirim konfirmasi. Selalu dengan approval supervisor dan nomor referensi.</span>
          </span>
          <ToggleSwitch v-model="form.manualConfirmAllowed" />
        </label>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label for="pm-sort" class="mb-1 block text-sm font-medium">Urutan</label>
            <InputNumber v-model="form.sortOrder" input-id="pm-sort" :min="0" :max="999" class="w-full" />
          </div>
          <div>
            <label for="pm-ob" class="mb-1 block text-sm font-medium">ID Openbravo</label>
            <InputText id="pm-ob" v-model="form.openbravoPaymentMethodId" class="w-full" maxlength="64" />
          </div>
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="editing = null" />
          <Button label="Simpan" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
