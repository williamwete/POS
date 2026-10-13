<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { BankAccount, FinanceBalance, LedgerEntry, Payout } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/** Saldo dari pembayaran QRIS/e-wallet lewat penyedia, rekening bank, dan pencairan dana. Hanya untuk pemilik. */
const { busy, run } = useApiAction()
const balance = ref<FinanceBalance | null>(null)
const ledger = ref<LedgerEntry[]>([])
const payouts = ref<Payout[]>([])
const bank = ref<BankAccount | null>(null)

const dateText = (iso?: string | null) => (iso ? new Date(iso).toLocaleString('id-ID', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—')
const TYPE_LABEL: Record<string, string> = {
  PAYMENT: 'Pembayaran', FEE: 'Biaya layanan', PAYMENT_REVERSAL: 'Pembayaran dibalik', FEE_REVERSAL: 'Biaya dikembalikan',
  REFUND: 'Refund', PAYOUT: 'Pencairan', PAYOUT_REVERSAL: 'Pencairan dibatalkan', ADJUSTMENT: 'Penyesuaian',
}
const STATUS: Record<string, { label: string; cls: string }> = {
  REQUESTED: { label: 'Menunggu', cls: 'bg-amber-100 text-amber-700' }, PROCESSING: { label: 'Diproses', cls: 'bg-amber-100 text-amber-700' },
  PAID: { label: 'Terkirim', cls: 'bg-jade-50 text-jade-700' }, REJECTED: { label: 'Ditolak', cls: 'bg-alert-50 text-alert-600' }, FAILED: { label: 'Gagal', cls: 'bg-alert-50 text-alert-600' },
}

async function load() {
  await run(async () => {
    const [b, l, p, a] = await Promise.all([
      api().get<FinanceBalance>('/api/finance/balance'), api().get<LedgerEntry[]>('/api/finance/ledger', { query: { limit: 100 } }),
      api().get<Payout[]>('/api/finance/payouts'), api().get<BankAccount | null>('/api/finance/bank-account'),
    ])
    balance.value = b.data; ledger.value = l.data; payouts.value = p.data; bank.value = a.data
  })
}
onMounted(load)

// ---- rekening
const bankOpen = ref(false)
const bankForm = reactive({ bankCode: '', accountNumber: '', accountName: '' })
const bankValid = computed(() => /^[A-Za-z0-9 ]{2,20}$/.test(bankForm.bankCode) && /^[0-9 -]{5,26}$/.test(bankForm.accountNumber) && bankForm.accountName.trim().length >= 2)
function openBank() {
  Object.assign(bankForm, { bankCode: bank.value?.bankCode ?? '', accountNumber: bank.value?.accountNumber ?? '', accountName: bank.value?.accountName ?? '' })
  bankOpen.value = true
}
async function saveBank() {
  if (!bankValid.value) return
  const ok = await run(() => api().put('/api/finance/bank-account', { ...bankForm, accountName: bankForm.accountName.trim() }), 'Rekening disimpan, menunggu verifikasi')
  if (ok) { bankOpen.value = false; await load() }
}
const mask = (n: string) => `••••${n.slice(-4)}`

// ---- pencairan
const payOpen = ref(false)
const amount = ref<number | null>(null)
const canPayout = computed(() => bank.value?.status === 'VERIFIED' && (balance.value?.available ?? 0) >= (balance.value?.minPayout ?? 0) && (balance.value?.available ?? 0) > 0)
const amountValid = computed(() => !!amount.value && amount.value >= (balance.value?.minPayout ?? 0) && amount.value <= (balance.value?.available ?? 0))
function openPayout() { amount.value = balance.value?.available ?? null; payOpen.value = true }
async function requestPayout() {
  if (!amountValid.value) return
  const ok = await run(() => api().post('/api/finance/payouts', { amount: amount.value }), 'Pencairan diajukan')
  if (ok) { payOpen.value = false; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Saldo & pencairan" description="Dana dari pembayaran QRIS/e-wallet yang diterima lewat penyedia pembayaran. Pembayaran tunai dan QRIS statis langsung ke Anda dan tidak masuk di sini." />

    <div v-if="balance" class="mb-6 grid gap-4 md:grid-cols-3">
      <div class="rounded-2xl border border-line bg-surface p-5">
        <p class="text-sm text-ink-soft">Dapat dicairkan</p>
        <p class="tabular mt-1 text-3xl font-bold">{{ formatRupiah(balance.available) }}</p>
        <Button class="mt-3" label="Cairkan dana" icon="pi pi-send" :disabled="!canPayout" @click="openPayout" />
        <p v-if="bank?.status !== 'VERIFIED'" class="mt-2 text-xs text-ink-soft">Isi rekening bank dan tunggu verifikasi untuk mencairkan.</p>
        <p v-else-if="!canPayout" class="mt-2 text-xs text-ink-soft">Minimal pencairan {{ formatRupiah(balance.minPayout) }}.</p>
      </div>
      <div class="rounded-2xl border border-line bg-surface p-5">
        <p class="text-sm text-ink-soft">Tertahan</p>
        <p class="tabular mt-1 text-3xl font-bold">{{ formatRupiah(balance.pending) }}</p>
        <p class="mt-2 text-xs text-ink-soft">Dana baru bisa dicairkan {{ balance.holdDays }} hari setelah pembayaran lunas.</p>
      </div>
      <div class="rounded-2xl border border-line bg-surface p-5">
        <p class="text-sm text-ink-soft">Rekening tujuan</p>
        <template v-if="bank">
          <p class="mt-1 font-semibold">{{ bank.bankCode }} {{ mask(bank.accountNumber) }}</p>
          <p class="text-sm text-ink-soft">{{ bank.accountName }}</p>
          <span :class="['mt-2 inline-flex rounded-full px-2 py-0.5 text-xs font-medium', bank.status === 'VERIFIED' ? 'bg-jade-50 text-jade-700' : 'bg-amber-100 text-amber-700']">{{ bank.status === 'VERIFIED' ? 'Terverifikasi' : 'Menunggu verifikasi' }}</span>
        </template>
        <p v-else class="mt-1 text-sm text-ink-soft">Belum diisi</p>
        <div><Button class="mt-3" :label="bank ? 'Ubah rekening' : 'Isi rekening'" icon="pi pi-pencil" severity="secondary" outlined size="small" @click="openBank" /></div>
      </div>
    </div>
    <p v-if="balance" class="mb-6 text-xs text-ink-faint">Biaya layanan {{ balance.feePercent }}%<template v-if="balance.feeFlat > 0"> + {{ formatRupiah(balance.feeFlat) }}</template> per pembayaran, dipotong otomatis dan tampil di riwayat.</p>

    <h2 class="mb-2 text-lg font-semibold">Pencairan</h2>
    <DataTable :value="payouts" data-key="id" class="mb-8 rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada pencairan.</template>
      <Column header="Diajukan"><template #body="{ data }">{{ dateText(data.requestedAt) }}</template></Column>
      <Column header="Jumlah"><template #body="{ data }"><span class="tabular font-semibold">{{ formatRupiah(data.amount) }}</span></template></Column>
      <Column header="Tujuan"><template #body="{ data }">{{ data.bankCode }} {{ mask(data.accountNumber) }}</template></Column>
      <Column header="Status"><template #body="{ data }"><span :class="['inline-flex rounded-full px-2 py-0.5 text-xs font-medium', STATUS[data.status]?.cls]">{{ STATUS[data.status]?.label }}</span></template></Column>
      <Column header="Keterangan"><template #body="{ data }"><span class="text-sm text-ink-soft">{{ data.providerRef ?? data.note ?? '' }}</span></template></Column>
    </DataTable>

    <h2 class="mb-2 text-lg font-semibold">Riwayat saldo</h2>
    <DataTable :value="ledger" data-key="id" class="rounded-2xl border border-line bg-surface" paginator :rows="15">
      <template #empty>Belum ada transaksi lewat penyedia pembayaran.</template>
      <Column header="Waktu"><template #body="{ data }">{{ dateText(data.createdAt) }}</template></Column>
      <Column header="Jenis"><template #body="{ data }">{{ TYPE_LABEL[data.entryType] ?? data.entryType }}<span v-if="data.description" class="block text-xs text-ink-faint">{{ data.description }}</span></template></Column>
      <Column header="Jumlah"><template #body="{ data }"><span :class="['tabular font-semibold', data.amount < 0 ? 'text-alert-600' : 'text-jade-700']">{{ data.amount < 0 ? '−' : '+' }}{{ formatRupiah(Math.abs(data.amount)) }}</span></template></Column>
      <Column header="Bisa dicairkan"><template #body="{ data }"><span class="text-sm text-ink-soft">{{ new Date(data.availableAt) <= new Date() ? 'Ya' : dateText(data.availableAt) }}</span></template></Column>
    </DataTable>

    <Dialog v-model:visible="bankOpen" header="Rekening bank tujuan" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="saveBank">
        <p class="text-sm text-ink-soft">Nama pemilik harus sama dengan nama usaha atau pemilik. Setiap perubahan diverifikasi ulang oleh tim kami sebelum pencairan.</p>
        <FormField label="Bank" for="bk-bank" required><InputText id="bk-bank" v-model="bankForm.bankCode" class="w-full uppercase" maxlength="20" placeholder="BCA, BNI, MANDIRI…" /></FormField>
        <FormField label="Nomor rekening" for="bk-no" required><InputText id="bk-no" v-model="bankForm.accountNumber" class="w-full" inputmode="numeric" maxlength="26" /></FormField>
        <FormField label="Nama pemilik rekening" for="bk-name" required><InputText id="bk-name" v-model="bankForm.accountName" class="w-full" maxlength="80" /></FormField>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="bankOpen = false" /><Button label="Simpan" type="submit" :loading="busy" :disabled="!bankValid" /></div>
      </form>
    </Dialog>

    <Dialog v-model:visible="payOpen" header="Cairkan dana" modal class="w-full max-w-sm">
      <form class="space-y-4" @submit.prevent="requestPayout">
        <p v-if="bank" class="text-sm text-ink-soft">Ke {{ bank.bankCode }} {{ mask(bank.accountNumber) }} a.n. {{ bank.accountName }}.</p>
        <FormField label="Jumlah" for="po-amt" required :hint="`Maks ${formatRupiah(balance?.available ?? 0)}, min ${formatRupiah(balance?.minPayout ?? 0)}`">
          <InputNumber v-model="amount" input-id="po-amt" class="w-full" prefix="Rp " locale="id-ID" :min="0" :max-fraction-digits="0" fluid />
        </FormField>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="payOpen = false" /><Button label="Ajukan pencairan" type="submit" :loading="busy" :disabled="!amountValid" /></div>
      </form>
    </Dialog>
  </div>
</template>
