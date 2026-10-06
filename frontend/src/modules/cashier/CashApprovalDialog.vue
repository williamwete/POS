<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Message from 'primevue/message'
import { useCashierStore } from '@/stores/cashier'
import { ApiError } from '@/services/apiClient'
import type { CashApprovalAction } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/**
 * Persetujuan supervisor untuk kas keluar besar / selisih kas. Supervisor memasukkan akunnya sendiri;
 * approval berlaku sekali, 2 menit, untuk nominal ini saja. Password tidak disimpan di state.
 */
const props = defineProps<{ sessionId: string; action: CashApprovalAction; amount: number; message?: string }>()
const visible = defineModel<boolean>('visible', { required: true })
const emit = defineEmits<{ approved: [id: string, approverName: string] }>()

const cashier = useCashierStore()
const email = ref('')
const password = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

watch(visible, (v) => {
  if (v) {
    email.value = ''
    password.value = ''
    error.value = null
  }
})

const LABEL: Record<CashApprovalAction, string> = { CASH_OUT: 'Kas keluar', CASH_DIFFERENCE: 'Selisih kas' }

async function submit() {
  if (!email.value || !password.value) return
  busy.value = true
  error.value = null
  const pwd = password.value
  password.value = ''
  try {
    const res = await cashier.approveCash(props.sessionId, props.action, props.amount, email.value.trim(), pwd)
    visible.value = false
    emit('approved', res.id, res.approverName)
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Persetujuan gagal.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Dialog v-model:visible="visible" modal header="Persetujuan supervisor" class="w-full max-w-md">
    <form class="space-y-4" autocomplete="off" @submit.prevent="submit">
      <div class="rounded-md bg-amber-100 p-3 text-sm">
        <div class="font-semibold">{{ LABEL[action] }} · <span class="tabular">{{ formatRupiah(amount) }}</span></div>
        <div v-if="message" class="mt-1 text-ink-soft">{{ message }}</div>
      </div>
      <p class="text-sm text-ink-soft">
        Supervisor/manager memasukkan akunnya sendiri di terminal ini. Persetujuan berlaku sekali, 2 menit,
        untuk nominal ini saja, dan tercatat atas nama approver.
      </p>
      <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>
      <div>
        <label for="cash-approver-email" class="mb-1 block text-sm font-medium">Email approver</label>
        <InputText id="cash-approver-email" v-model="email" type="email" class="w-full" autocomplete="off" />
      </div>
      <div>
        <label for="cash-approver-password" class="mb-1 block text-sm font-medium">Password approver</label>
        <Password v-model="password" input-id="cash-approver-password" :feedback="false" toggle-mask class="w-full"
          input-class="w-full" autocomplete="new-password" />
      </div>
      <div class="flex justify-end gap-2">
        <Button label="Batal" text severity="secondary" type="button" @click="visible = false" />
        <Button label="Setujui" icon="pi pi-check" type="submit" :loading="busy" :disabled="!email || !password" />
      </div>
    </form>
  </Dialog>
</template>
