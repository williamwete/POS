<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import Textarea from 'primevue/textarea'
import SelectButton from 'primevue/selectbutton'
import { useToast } from 'primevue/usetoast'
import { useCashierStore } from '@/stores/cashier'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'
import { formatRupiah } from '@/utils/money'
import CashApprovalDialog from './CashApprovalDialog.vue'

/**
 * Kas masuk / kas keluar / petty cash oleh pemegang laci (§25). Server memeriksa saldo laci, ambang
 * approval, dan mengisi outlet/tanggal bisnis; kas keluar di atas ambang meminta approval supervisor.
 */
type MoveType = 'CASH_IN' | 'CASH_OUT' | 'PETTY_CASH'
const props = defineProps<{ initialType?: MoveType }>()
const visible = defineModel<boolean>('visible', { required: true })
const emit = defineEmits<{ done: [] }>()

const cashier = useCashierStore()
const toast = useToast()
const type = ref<MoveType>('CASH_IN')
const amount = ref<number | null>(null)
const reason = ref('')
const busy = ref(false)
const approvalOpen = ref(false)
let key: string | null = null

const TYPES = [
  { value: 'CASH_IN', label: 'Kas masuk' },
  { value: 'CASH_OUT', label: 'Kas keluar' },
  { value: 'PETTY_CASH', label: 'Petty cash' },
]
const HINT: Record<MoveType, string> = {
  CASH_IN: 'Uang yang ditambahkan ke laci, mis. tambahan uang kembalian dari brankas.',
  CASH_OUT: 'Uang yang diambil dari laci, mis. setor sebagian ke brankas atau bayar kurir.',
  PETTY_CASH: 'Pengeluaran kecil operasional toko dari laci, mis. beli plastik atau galon.',
}

watch(visible, (v) => {
  if (v) {
    type.value = props.initialType ?? 'CASH_IN'
    amount.value = null
    reason.value = ''
    key = null
  }
})

const valid = computed(() => !!amount.value && amount.value > 0 && reason.value.trim().length >= 3)

async function submit(approvalId: string | null = null) {
  if (!valid.value || busy.value) return
  busy.value = true
  key ??= newIdempotencyKey()
  try {
    await cashier.cashMovement(type.value, amount.value!, reason.value.trim(), approvalId, key)
    toast.add({ severity: 'success', summary: type.value === 'CASH_IN' ? 'Kas masuk tercatat' : 'Kas keluar tercatat', life: 2500 })
    key = null
    visible.value = false
    emit('done')
  } catch (e) {
    if (e instanceof ApiError && e.status >= 400 && e.status < 500) key = null
    if (e instanceof ApiError && e.code === 'APPROVAL_REQUIRED' && !approvalId) {
      approvalOpen.value = true
    } else {
      toast.add({ severity: 'error', summary: e instanceof ApiError ? e.message : 'Gagal mencatat kas.', life: 6000 })
    }
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Dialog v-model:visible="visible" modal header="Kas masuk / keluar" class="w-full max-w-md">
    <form class="space-y-4" @submit.prevent="submit()">
      <SelectButton v-model="type" :options="TYPES" option-label="label" option-value="value" :allow-empty="false"
        class="w-full" aria-label="Jenis" />
      <p class="text-sm text-ink-soft">{{ HINT[type] }}</p>
      <div>
        <label for="move-amount" class="mb-1 block text-sm font-medium">Nominal</label>
        <InputNumber v-model="amount" input-id="move-amount" mode="currency" currency="IDR" locale="id-ID"
          :min-fraction-digits="0" :max-fraction-digits="0" :min="0" class="w-full" input-class="w-full tabular text-lg" />
      </div>
      <div>
        <label for="move-reason" class="mb-1 block text-sm font-medium">Alasan</label>
        <Textarea id="move-reason" v-model="reason" rows="2" maxlength="500" class="w-full"
          :placeholder="type === 'CASH_IN' ? 'Mis. tambahan uang receh dari brankas' : 'Mis. bayar kurir galon'" />
        <p class="mt-1 text-xs text-ink-faint">Wajib, minimal 3 karakter. Tercatat di audit log.</p>
      </div>
      <p v-if="type !== 'CASH_IN'" class="text-xs text-ink-faint">
        Kas keluar di atas batas outlet memerlukan persetujuan supervisor.
      </p>
      <div class="flex justify-end gap-2">
        <Button label="Batal" text severity="secondary" type="button" @click="visible = false" />
        <Button :label="`Simpan · ${formatRupiah(amount ?? 0)}`" type="submit" :loading="busy" :disabled="!valid" />
      </div>
    </form>
    <CashApprovalDialog
      v-if="cashier.current"
      v-model:visible="approvalOpen"
      :session-id="cashier.current.id"
      action="CASH_OUT"
      :amount="amount ?? 0"
      message="Kas keluar melewati batas outlet."
      @approved="(id) => submit(id)"
    />
  </Dialog>
</template>
