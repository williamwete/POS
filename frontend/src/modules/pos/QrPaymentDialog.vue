<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import QRCode from 'qrcode'
import { useToast } from 'primevue/usetoast'
import type { Payment } from '@/types/api'
import { usePaymentStore } from '@/stores/payment'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'
import { formatRupiah } from '@/utils/money'
import { useApprovalPrompt } from './approvalPrompt'

/**
 * Menunggu pembayaran QRIS/e-wallet (§64). Status hanya berubah dari server (callback penyedia atau
 * polling server ke penyedia); layar ini sekadar bertanya berkala.
 */
const props = defineProps<{ paymentId: string | null }>()
const emit = defineEmits<{ close: [] }>()
const payments = usePaymentStore()
const toast = useToast()
const prompt = useApprovalPrompt()

const qr = ref<string | null>(null)
const now = ref(Date.now())
const busy = ref(false)
const manualRef = ref('')
let poll: number | undefined
let tick: number | undefined

const payment = computed<Payment | null>(() => payments.payments.find((p) => p.id === props.paymentId) ?? null)
const visible = computed(() => !!props.paymentId)
const remainingSec = computed(() => {
  const exp = payment.value?.expiresAt ? new Date(payment.value.expiresAt).getTime() : 0
  return Math.max(0, Math.floor((exp - now.value) / 1000))
})
const countdown = computed(() => `${Math.floor(remainingSec.value / 60)}:${String(remainingSec.value % 60).padStart(2, '0')}`)
const staticMode = computed(() => !!payment.value && !payment.value.qrPayload)

async function render() {
  qr.value = payment.value?.qrPayload
    ? await QRCode.toDataURL(payment.value.qrPayload, { margin: 1, width: 240, errorCorrectionLevel: 'M' })
    : null
}

function stop() {
  window.clearInterval(poll)
  window.clearInterval(tick)
  poll = tick = undefined
}

watch(() => props.paymentId, async (id) => {
  stop()
  manualRef.value = ''
  if (!id) return
  await render()
  tick = window.setInterval(() => (now.value = Date.now()), 1000)
  poll = window.setInterval(() => void check(), 2500)
}, { immediate: true })
onBeforeUnmount(stop)

watch(() => payment.value?.status, (st) => {
  if (!st || st === 'PENDING') return
  stop()
  if (st === 'PAID') {
    toast.add({ severity: 'success', summary: `Pembayaran ${payment.value?.methodName} diterima`, life: 2500 })
    emit('close')
  }
})

async function check() {
  if (!props.paymentId || payment.value?.status !== 'PENDING') return
  try {
    await payments.refresh(props.paymentId)
  } catch {
    // jaringan putus sesaat: coba lagi di putaran berikutnya
  }
}

function fail(e: unknown) {
  toast.add({ severity: 'error', summary: e instanceof ApiError ? e.message : 'Terjadi kesalahan tak terduga.', life: 5000 })
}

async function cancel() {
  if (!props.paymentId) return
  busy.value = true
  try {
    await payments.cancel(props.paymentId, 'Pelanggan batal / ganti metode pembayaran', newIdempotencyKey())
    emit('close')
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

async function confirmManual() {
  const p = payment.value
  if (!p || manualRef.value.trim().length < 3) return
  const approvalId = await prompt.ask({ action: 'PAYMENT_CONFIRM', saleId: p.saleId, price: p.amount },
    'Konfirmasi manual pembayaran memerlukan persetujuan supervisor.')
  if (!approvalId) return
  busy.value = true
  try {
    await payments.confirm(p.id, manualRef.value.trim(), approvalId, newIdempotencyKey())
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

async function simulate(result: 'PAID' | 'FAILED') {
  if (!props.paymentId) return
  busy.value = true
  try {
    await payments.simulate(props.paymentId, result)
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Dialog :visible="visible" modal :closable="payment?.status !== 'PENDING'" :header="payment ? `Bayar dengan ${payment.methodName}` : ''"
    class="w-full max-w-md" @update:visible="(v) => { if (!v) emit('close') }">
    <div v-if="payment" class="text-center">
      <p class="text-sm text-ink-soft">Jumlah</p>
      <p class="tabular text-3xl font-bold">{{ formatRupiah(payment.amount) }}</p>

      <template v-if="payment.status === 'PENDING'">
        <div v-if="qr" class="mx-auto mt-4 inline-block rounded-lg border-4 border-jade-700 bg-white p-2">
          <img :src="qr" :alt="`Kode QR ${payment.methodName}`" width="240" height="240" />
        </div>
        <p v-else class="mt-4 rounded-md bg-field p-4 text-sm">
          Minta pelanggan memindai <strong>QRIS statis outlet</strong>, lalu periksa dana masuk di aplikasi merchant
          sebelum konfirmasi.
        </p>
        <p v-if="!staticMode" class="mt-3 flex items-center justify-center gap-2 text-sm text-ink-soft">
          <i class="pi pi-spin pi-spinner" aria-hidden="true" /> Menunggu konfirmasi penyedia pembayaran
        </p>
        <p class="mt-1 text-xs text-ink-faint">Batas waktu <span class="tabular">{{ countdown }}</span></p>

        <div v-if="payment.manualConfirmAllowed" class="mt-5 space-y-2 border-t border-line pt-4 text-left">
          <label for="manual-ref" class="block text-sm font-medium">No. referensi (RRN) dari aplikasi merchant</label>
          <InputText id="manual-ref" v-model="manualRef" class="tabular w-full" maxlength="64" />
          <Button label="Konfirmasi manual (perlu supervisor)" icon="pi pi-check" severity="secondary" class="w-full"
            :disabled="manualRef.trim().length < 3" :loading="busy" @click="confirmManual" />
        </div>

        <div v-if="payments.simulated" class="mt-5 rounded-md border border-dashed border-amber-500 p-3 text-left">
          <p class="text-xs font-semibold text-amber-700">Mode pengembangan — penyedia pembayaran tiruan</p>
          <div class="mt-2 flex gap-2">
            <Button label="Simulasikan dibayar" size="small" :loading="busy" @click="simulate('PAID')" />
            <Button label="Simulasikan gagal" size="small" severity="secondary" outlined :loading="busy" @click="simulate('FAILED')" />
          </div>
        </div>

        <Button label="Batalkan pembayaran ini" severity="danger" text class="mt-4" :loading="busy" @click="cancel" />
      </template>
      <p v-else-if="payment.status === 'FAILED'" class="mt-4 rounded-md bg-alert-50 p-3 text-sm text-alert-600">
        Pembayaran gagal ({{ payment.failedReason }}). Pilih metode lain atau coba lagi.
      </p>
      <p v-else-if="payment.status === 'CANCELLED'" class="mt-4 rounded-md bg-field p-3 text-sm">{{ payment.cancelReason }}</p>
    </div>
  </Dialog>
</template>
