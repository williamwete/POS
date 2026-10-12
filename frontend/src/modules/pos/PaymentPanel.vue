<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import InputText from 'primevue/inputtext'
import { useToast } from 'primevue/usetoast'
import { useSaleStore } from '@/stores/sale'
import { newClientPaymentId, usePaymentStore } from '@/stores/payment'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'
import { formatRupiah } from '@/utils/money'
import type { Payment, PaymentMethod } from '@/types/api'
import { useApprovalPrompt } from './approvalPrompt'
import { PAYMENT_STATUS_CLASS, PAYMENT_STATUS_LABEL, referenceLabel } from './paymentFormat'
import QrPaymentDialog from './QrPaymentDialog.vue'
import ReasonDialog from './ReasonDialog.vue'

/**
 * Pembayaran setelah checkout (§22–§24): satu atau beberapa metode (split). Server menghitung jumlah
 * yang diterapkan, kembalian, dan status lunas.
 */
const emit = defineEmits<{ reopen: []; void: []; receipt: [] }>()
const sales = useSaleStore()
const payments = usePaymentStore()
const toast = useToast()
const prompt = useApprovalPrompt()

const busy = ref(false)
const method = ref<PaymentMethod | null>(null)
const received = ref<number | null>(null)
const amount = ref<number | null>(null)
const reference = ref('')
const qrPaymentId = ref<string | null>(null)
const cashInput = ref<{ $el: HTMLElement } | null>(null)

const s = computed(() => sales.sale!)
const pendingTotal = computed(() => payments.pending.reduce((a, p) => a + p.amount, 0))
const remaining = computed(() => Math.max(0, s.value.grandTotal - s.value.paidAmount - pendingTotal.value))
const usable = computed(() => payments.methods.filter((m) => m.available))
const isCash = computed(() => method.value?.kind === 'CASH')
const change = computed(() => (isCash.value && received.value ? Math.max(0, received.value - remaining.value) : 0))
const visiblePayments = computed(() => payments.payments.filter((p) => p.status !== 'CANCELLED' || p.paidAt))
const canSubmit = computed(() => {
  if (!method.value || remaining.value <= 0 || busy.value) return false
  if (isCash.value) return !!received.value && received.value > 0
  if (!amount.value || amount.value <= 0 || amount.value > remaining.value) return false
  return !method.value.requiresReference || reference.value.trim().length >= 3
})

onMounted(async () => {
  try {
    await Promise.all([payments.methods.length ? Promise.resolve() : payments.loadMethods(), payments.load(s.value.id)])
  } catch (e) {
    fail(e)
  }
  if (!method.value) select(usable.value.find((m) => m.kind === 'CASH') ?? usable.value[0] ?? null)
  const waiting = payments.pending.find((p) => p.confirmation === 'GATEWAY')
  if (waiting) qrPaymentId.value = waiting.id
})

watch(remaining, (r) => {
  if (!isCash.value) amount.value = r || null
})

function select(m: PaymentMethod | null) {
  method.value = m
  received.value = null
  reference.value = ''
  amount.value = remaining.value || null
  if (m?.kind === 'CASH') void nextTick(() => cashInput.value?.$el.querySelector('input')?.focus())
}

function fail(e: unknown) {
  toast.add({
    severity: 'error',
    summary: e instanceof ApiError ? e.message : 'Terjadi kesalahan tak terduga.',
    detail: e instanceof ApiError && e.requestId ? `Kode request: ${e.requestId}` : undefined,
    life: 5000,
  })
}

async function submit() {
  const m = method.value
  if (!m || !canSubmit.value) return
  // ID pembayaran dibuat sekali per percobaan; dipakai ulang bila perlu mengulang dengan approval
  const clientPaymentId = newClientPaymentId()
  const body = {
    clientPaymentId,
    methodCode: m.code,
    amount: isCash.value ? undefined : amount.value ?? undefined,
    amountReceived: isCash.value ? received.value ?? undefined : undefined,
    referenceNumber: reference.value.trim() || undefined,
  }
  busy.value = true
  try {
    let r
    try {
      r = await payments.add(s.value.id, body, newIdempotencyKey())
    } catch (e) {
      if (!(e instanceof ApiError && e.code === 'APPROVAL_REQUIRED')) throw e
      busy.value = false
      const approvalId = await prompt.ask({ action: 'PAYMENT_CONFIRM', saleId: s.value.id, price: body.amount }, e.message)
      if (!approvalId) return
      busy.value = true
      r = await payments.add(s.value.id, { ...body, clientPaymentId: newClientPaymentId(), approvalId }, newIdempotencyKey())
    }
    if (r.payment.status === 'PENDING') qrPaymentId.value = r.payment.id
    else toast.add({ severity: 'success', summary: `${r.payment.methodName} ${formatRupiah(r.payment.amount)} diterima`, life: 2000 })
    select(r.sale.status === 'PAID' ? method.value : usable.value.find((x) => x.kind === 'CASH') ?? method.value)
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

// ---- batalkan / balikkan pembayaran
const cancelTarget = ref<Payment | null>(null)
async function confirmCancel(reason: string) {
  const p = cancelTarget.value
  if (!p) return
  busy.value = true
  try {
    await payments.cancel(p.id, reason, newIdempotencyKey())
    cancelTarget.value = null
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}
const canReverse = (p: Payment) =>
  p.status === 'PENDING' || (p.status === 'PAID' && p.confirmation !== 'GATEWAY' && s.value.status !== 'PAID')
const cashMethod = computed(() => usable.value.find((m) => m.kind === 'CASH') ?? null)
const cashless = computed(() => usable.value.filter((m) => m.kind !== 'CASH'))
const tab = computed<'cash' | 'cashless'>(() => (isCash.value ? 'cash' : 'cashless'))
function setTab(t: 'cash' | 'cashless') {
  if (t === 'cash' && cashMethod.value) select(cashMethod.value)
  else if (t === 'cashless' && cashless.value.length) select(cashless.value[0]!)
}
const hasPayments = computed(() => payments.payments.some((p) => p.status === 'PAID' || p.status === 'PENDING'))
</script>

<template>
  <section class="px-2 pb-2" aria-labelledby="pay-title">
    <h2 id="pay-title" class="text-center text-xl font-semibold">Payment Method</h2>
    <p class="mt-5 text-sm">Order No : <span class="tabular">{{ s.receiptNo?.split('-').pop() }}</span></p>
    <p class="text-sm">Item <span class="ml-6">: {{ s.itemCount }}</span></p>
    <p class="tabular my-2 text-center text-3xl font-bold" aria-live="polite">{{ formatRupiah(remaining) }}</p>
    <p v-if="s.paidAmount > 0" class="mb-2 text-center text-xs text-ink-soft">Sudah dibayar {{ formatRupiah(s.paidAmount) }} dari {{ formatRupiah(s.grandTotal) }}</p>

    <div v-if="remaining > 0">
      <div class="grid grid-cols-2 overflow-hidden rounded-lg border border-line text-sm font-medium" role="tablist">
        <button type="button" role="tab" :aria-selected="tab === 'cash'" :disabled="busy || !cashMethod"
          :class="['py-2', tab === 'cash' ? 'bg-jade-100' : 'bg-white']" @click="setTab('cash')">Cash</button>
        <button type="button" role="tab" :aria-selected="tab === 'cashless'" :disabled="busy || !cashless.length"
          :class="['py-2', tab === 'cashless' ? 'bg-jade-100' : 'bg-white']" @click="setTab('cashless')">Cashless</button>
      </div>

      <form v-if="method" class="mt-4 space-y-3" @submit.prevent="submit">
        <template v-if="isCash">
          <Button type="button" label="Exact Change" severity="secondary" size="small" @click="received = remaining" />
          <div>
            <label for="cash-received" class="mb-1 block text-sm">Money Received</label>
            <InputNumber ref="cashInput" v-model="received" input-id="cash-received" :min="1" :max="999999999"
              locale="id-ID" prefix="Rp " class="w-full" input-class="tabular w-full" placeholder="Rp" />
          </div>
          <div class="flex justify-between text-sm"><span>Change</span>
            <span class="tabular font-bold">{{ formatRupiah(change) }}</span></div>
          <p v-if="received && received < remaining" class="text-xs text-amber-700">
            Kurang {{ formatRupiah(remaining - received) }} — sisanya bisa dibayar dengan metode lain (split).
          </p>
        </template>
        <template v-else>
          <div v-if="cashless.length > 1" class="flex flex-wrap gap-2">
            <button v-for="m in cashless" :key="m.id" type="button"
              :class="['rounded-lg border px-3 py-1 text-sm', method.id === m.id ? 'border-jade-500 bg-jade-100' : 'border-line']"
              @click="select(m)">{{ m.name }}</button>
          </div>
          <p class="text-center text-sm text-ink-soft">{{ method.name }} · {{ formatRupiah(amount ?? 0) }}</p>
          <div v-if="method.requiresReference">
            <label for="pay-ref" class="mb-1 block text-sm">{{ referenceLabel(method.kind) }}</label>
            <InputText id="pay-ref" v-model="reference" class="tabular w-full" maxlength="64" autocomplete="off" />
          </div>
          <p v-if="method.requiresApproval && method.confirmation === 'MANUAL'" class="text-xs text-amber-700">
            Pembayaran ini memerlukan konfirmasi supervisor.
          </p>
        </template>
        <div class="grid gap-3 pt-2">
          <Button type="submit" label="Confirm" :disabled="!canSubmit" :loading="busy" />
          <Button type="button" label="Cancel" severity="danger" outlined :disabled="busy || hasPayments" @click="emit('reopen')" />
        </div>
      </form>
    </div>
    <p v-else-if="payments.pending.length" class="p-4 text-sm text-ink-soft">Menunggu konfirmasi pembayaran.</p>

    <ul v-if="visiblePayments.length" class="mt-4 divide-y divide-line border-t border-line text-sm" aria-label="Pembayaran tercatat">
      <li v-for="p in visiblePayments" :key="p.id" class="flex items-center gap-2 py-2">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="font-medium">{{ p.methodName }}</span>
            <span :class="['rounded-full px-2 py-0.5 text-[11px] font-medium', PAYMENT_STATUS_CLASS[p.status]]">{{ PAYMENT_STATUS_LABEL[p.status] }}</span>
          </div>
          <div class="text-xs text-ink-soft">
            <template v-if="p.methodKind === 'CASH'">diterima {{ formatRupiah(p.amountReceived) }} · kembali {{ formatRupiah(p.changeAmount) }}</template>
            <template v-else-if="p.referenceNumber">ref {{ p.referenceNumber }}</template>
          </div>
        </div>
        <span class="tabular font-semibold" :class="p.status === 'CANCELLED' ? 'text-ink-faint line-through' : ''">{{ formatRupiah(p.amount) }}</span>
        <Button v-if="p.status === 'PENDING' && p.confirmation === 'GATEWAY'" icon="pi pi-qrcode" text rounded size="small"
          :aria-label="`Lihat QR ${p.methodName}`" @click="qrPaymentId = p.id" />
        <Button v-if="canReverse(p)" icon="pi pi-times" text rounded size="small" severity="danger"
          :aria-label="`Batalkan pembayaran ${p.methodName}`" :disabled="busy" @click="cancelTarget = p" />
      </li>
    </ul>
    <p v-if="hasPayments" class="mt-2 text-xs text-ink-faint">Batalkan pembayaran yang ada untuk kembali ke keranjang.</p>

    <QrPaymentDialog :payment-id="qrPaymentId" @close="qrPaymentId = null" />
    <ReasonDialog :visible="!!cancelTarget" :title="`Batalkan pembayaran ${cancelTarget?.methodName ?? ''}`"
      :description="cancelTarget?.methodKind === 'CASH' ? 'Uang dikembalikan ke pelanggan; laci kas dicatat berkurang sebesar pembayaran ini.' : 'Pembayaran ditandai batal dan tercatat di audit log.'"
      :presets="['Pelanggan ganti metode', 'Salah input jumlah', 'Pelanggan batal belanja']" :min-length="5"
      confirm-label="Batalkan pembayaran" :busy="busy" @update:visible="(v: boolean) => { if (!v) cancelTarget = null }" @confirm="confirmCancel" />
  </section>
</template>
