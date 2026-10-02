<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Message from 'primevue/message'
import { useSaleStore } from '@/stores/sale'
import { ApiError } from '@/services/apiClient'
import { formatRupiah } from '@/utils/money'
import { useApprovalPrompt } from './approvalPrompt'

const { state, finish } = useApprovalPrompt()
const sales = useSaleStore()
const email = ref('')
const password = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

watch(() => state.visible, (v) => {
  if (v) {
    email.value = ''
    password.value = ''
    error.value = null
  }
})

const ACTION_LABEL: Record<string, string> = {
  DISCOUNT: 'Diskon',
  PRICE_OVERRIDE: 'Ubah harga',
  VOID_SALE: 'Void transaksi',
}

function detail(): string {
  const p = state.payload
  if (!p) return ''
  if (p.action === 'DISCOUNT') {
    return p.discountType === 'PERCENTAGE' ? `${p.discountValue}%` : formatRupiah(p.discountValue)
  }
  if (p.action === 'PRICE_OVERRIDE') return `Harga baru ${formatRupiah(p.price)}`
  return sales.sale?.receiptNo ?? ''
}

async function submit() {
  if (!state.payload || !email.value || !password.value) return
  busy.value = true
  error.value = null
  const pwd = password.value
  password.value = ''
  try {
    const res = await sales.approve(state.payload, email.value.trim(), pwd)
    finish(res.id)
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Persetujuan gagal.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Dialog
    :visible="state.visible"
    modal
    header="Persetujuan supervisor"
    class="w-full max-w-md"
    @update:visible="(v) => { if (!v) finish(null) }"
  >
    <form class="space-y-4" autocomplete="off" @submit.prevent="submit">
      <div class="rounded-md bg-amber-100 p-3 text-sm">
        <div class="font-semibold">{{ ACTION_LABEL[state.payload?.action ?? ''] }} · <span class="tabular">{{ detail() }}</span></div>
        <div class="mt-1 text-ink-soft">{{ state.message }}</div>
      </div>
      <p class="text-sm text-ink-soft">
        Supervisor/manager memasukkan akunnya sendiri di terminal ini. Persetujuan berlaku sekali, 2 menit,
        dan tercatat atas nama approver.
      </p>
      <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>
      <div>
        <label for="approver-email" class="mb-1 block text-sm font-medium">Email approver</label>
        <InputText id="approver-email" v-model="email" type="email" class="w-full" autocomplete="off" />
      </div>
      <div>
        <label for="approver-password" class="mb-1 block text-sm font-medium">Password approver</label>
        <Password v-model="password" input-id="approver-password" :feedback="false" toggle-mask class="w-full"
          input-class="w-full" autocomplete="new-password" />
      </div>
      <div class="flex justify-end gap-2">
        <Button label="Batal" text severity="secondary" type="button" @click="finish(null)" />
        <Button label="Setujui" icon="pi pi-check" type="submit" :loading="busy" :disabled="!email || !password" />
      </div>
    </form>
  </Dialog>
</template>
