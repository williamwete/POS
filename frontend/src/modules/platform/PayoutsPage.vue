<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
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
import type { MerchantBalance, PlatformBankAccount, PlatformPayout } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/**
 * Operator: antrean pencairan, verifikasi rekening merchant, dan kewajiban platform ke merchant.
 * Transfer dilakukan manual (atau lewat API disbursement penyedia nanti); di sini hanya dicatat hasilnya.
 */
const { busy, run } = useApiAction()
const payouts = ref<PlatformPayout[]>([])
const banks = ref<PlatformBankAccount[]>([])
const balances = ref<MerchantBalance[]>([])
const dateText = (iso?: string | null) => (iso ? new Date(iso).toLocaleString('id-ID', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—')
const totalLiability = () => balances.value.reduce((s, b) => s + b.total, 0)

async function load() {
  await run(async () => {
    const [p, b, bal] = await Promise.all([
      api().get<PlatformPayout[]>('/api/platform/payouts'), api().get<PlatformBankAccount[]>('/api/platform/bank-accounts'),
      api().get<MerchantBalance[]>('/api/platform/balances'),
    ])
    payouts.value = p.data; banks.value = b.data; balances.value = bal.data
  })
}
onMounted(load)

// ---- proses pencairan
const target = ref<PlatformPayout | null>(null)
const mode = ref<'PAID' | 'REJECTED'>('PAID')
const text = ref('')
function openProcess(p: PlatformPayout, m: 'PAID' | 'REJECTED') { target.value = p; mode.value = m; text.value = '' }
async function process() {
  if (!target.value || text.value.trim().length < (mode.value === 'PAID' ? 3 : 5)) return
  const body = mode.value === 'PAID' ? { status: 'PAID', reference: text.value.trim() } : { status: 'REJECTED', note: text.value.trim() }
  const ok = await run(() => api().put(`/api/platform/payouts/${target.value!.id}`, body), mode.value === 'PAID' ? 'Ditandai terkirim' : 'Pencairan ditolak, saldo dikembalikan')
  if (ok) { target.value = null; await load() }
}

async function verify(b: PlatformBankAccount, verified: boolean) {
  const ok = await run(() => api().put(`/api/platform/merchants/${b.organizationId}/bank-account/verify`, { verified }), verified ? 'Rekening diverifikasi' : 'Verifikasi dicabut')
  if (ok) await load()
}

// ---- ketentuan biaya
const terms = ref<MerchantBalance | null>(null)
const tf = reactive({ feePercent: 0.7, feeFlat: 0, holdDays: 1, minPayout: 50000 })
function openTerms(b: MerchantBalance) { terms.value = b; Object.assign(tf, { feePercent: b.feePercent, feeFlat: b.feeFlat, holdDays: b.holdDays, minPayout: b.minPayout }) }
async function saveTerms() {
  const ok = await run(() => api().put(`/api/platform/merchants/${terms.value!.organizationId}/terms`, { ...tf }), 'Ketentuan disimpan')
  if (ok) { terms.value = null; await load() }
}
</script>

<template>
  <div>
    <PageHeader title="Pencairan" description="Antrean pencairan dana merchant, verifikasi rekening, dan kewajiban platform. Cocokkan total kewajiban dengan saldo rekening penampung." />

    <h2 class="mb-2 text-lg font-semibold">Antrean pencairan</h2>
    <DataTable :value="payouts" data-key="id" class="mb-8 rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada pencairan.</template>
      <Column header="Merchant"><template #body="{ data }"><div class="font-semibold">{{ data.merchantName }}</div><div class="text-xs text-ink-faint">{{ data.merchantCode }} · {{ dateText(data.requestedAt) }}</div></template></Column>
      <Column header="Jumlah"><template #body="{ data }"><span class="tabular font-semibold">{{ formatRupiah(data.amount) }}</span></template></Column>
      <Column header="Transfer ke"><template #body="{ data }"><div>{{ data.bankCode }} <span class="font-mono">{{ data.accountNumber }}</span></div><div class="text-xs text-ink-faint">{{ data.accountName }}</div></template></Column>
      <Column header="Status"><template #body="{ data }">{{ data.status }}<div v-if="data.providerRef || data.note" class="text-xs text-ink-faint">{{ data.providerRef ?? data.note }}</div></template></Column>
      <Column class="w-48">
        <template #body="{ data }">
          <template v-if="data.status === 'REQUESTED' || data.status === 'PROCESSING'">
            <Button label="Sudah transfer" size="small" @click="openProcess(data, 'PAID')" />
            <Button label="Tolak" size="small" severity="danger" text @click="openProcess(data, 'REJECTED')" />
          </template>
        </template>
      </Column>
    </DataTable>

    <h2 class="mb-2 text-lg font-semibold">Rekening merchant</h2>
    <DataTable :value="banks" data-key="organizationId" class="mb-8 rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada rekening yang diisi.</template>
      <Column header="Merchant"><template #body="{ data }"><div class="font-semibold">{{ data.merchantName }}</div><div class="text-xs text-ink-faint">{{ data.merchantCode }}</div></template></Column>
      <Column header="Rekening"><template #body="{ data }">{{ data.bankCode }} <span class="font-mono">{{ data.accountNumber }}</span><div class="text-xs text-ink-faint">a.n. {{ data.accountName }}</div></template></Column>
      <Column header="Status"><template #body="{ data }"><span :class="['inline-flex rounded-full px-2 py-0.5 text-xs font-medium', data.status === 'VERIFIED' ? 'bg-jade-50 text-jade-700' : 'bg-amber-100 text-amber-700']">{{ data.status === 'VERIFIED' ? 'Terverifikasi' : 'Menunggu' }}</span></template></Column>
      <Column class="w-44"><template #body="{ data }"><Button v-if="data.status === 'PENDING'" label="Verifikasi" size="small" @click="verify(data, true)" /><Button v-else label="Cabut" size="small" text severity="secondary" @click="verify(data, false)" /></template></Column>
    </DataTable>

    <h2 class="mb-1 text-lg font-semibold">Saldo merchant</h2>
    <p class="mb-2 text-sm text-ink-soft">Total kewajiban ke semua merchant: <strong class="tabular">{{ formatRupiah(totalLiability()) }}</strong></p>
    <DataTable :value="balances" data-key="organizationId" class="rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada merchant.</template>
      <Column header="Merchant"><template #body="{ data }"><div class="font-semibold">{{ data.merchantName }}</div><div class="text-xs text-ink-faint">{{ data.merchantCode }}</div></template></Column>
      <Column header="Saldo"><template #body="{ data }"><span class="tabular">{{ formatRupiah(data.total) }}</span></template></Column>
      <Column header="Dapat dicairkan"><template #body="{ data }"><span class="tabular">{{ formatRupiah(data.available) }}</span></template></Column>
      <Column header="Biaya · tahan · min"><template #body="{ data }"><span class="text-sm">{{ data.feePercent }}%<template v-if="data.feeFlat > 0"> + {{ formatRupiah(data.feeFlat) }}</template> · {{ data.holdDays }} hari · {{ formatRupiah(data.minPayout) }}</span></template></Column>
      <Column class="w-16"><template #body="{ data }"><Button icon="pi pi-sliders-h" text rounded :aria-label="`Ketentuan ${data.merchantName}`" @click="openTerms(data)" /></template></Column>
    </DataTable>

    <Dialog :visible="!!target" :header="mode === 'PAID' ? 'Tandai sudah ditransfer' : 'Tolak pencairan'" modal class="w-full max-w-md" @update:visible="target = null">
      <form v-if="target" class="space-y-4" @submit.prevent="process">
        <p class="text-sm text-ink-soft">{{ target.merchantName }} · {{ formatRupiah(target.amount) }} ke {{ target.bankCode }} {{ target.accountNumber }}</p>
        <FormField :label="mode === 'PAID' ? 'Nomor referensi transfer' : 'Alasan penolakan'" for="pr-text" required :hint="mode === 'REJECTED' ? 'Saldo dikembalikan ke merchant' : 'Dari bukti transfer bank'">
          <InputText id="pr-text" v-model="text" class="w-full" maxlength="100" />
        </FormField>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="target = null" /><Button :label="mode === 'PAID' ? 'Simpan' : 'Tolak pencairan'" type="submit" :severity="mode === 'PAID' ? undefined : 'danger'" :loading="busy" /></div>
      </form>
    </Dialog>

    <Dialog :visible="!!terms" header="Ketentuan merchant" modal class="w-full max-w-md" @update:visible="terms = null">
      <form v-if="terms" class="grid gap-4 sm:grid-cols-2" @submit.prevent="saveTerms">
        <p class="text-sm text-ink-soft sm:col-span-2">{{ terms.merchantName }}. Berlaku untuk pembayaran berikutnya; entri yang sudah tercatat tidak berubah.</p>
        <FormField label="Biaya (%)" for="t-pct"><InputNumber v-model="tf.feePercent" input-id="t-pct" class="w-full" :min="0" :max="20" :max-fraction-digits="3" suffix=" %" fluid /></FormField>
        <FormField label="Biaya tetap (Rp)" for="t-flat"><InputNumber v-model="tf.feeFlat" input-id="t-flat" class="w-full" :min="0" :max="100000" prefix="Rp " locale="id-ID" fluid /></FormField>
        <FormField label="Masa tahan (hari)" for="t-hold"><InputNumber v-model="tf.holdDays" input-id="t-hold" class="w-full" :min="0" :max="30" fluid /></FormField>
        <FormField label="Minimal pencairan" for="t-min"><InputNumber v-model="tf.minPayout" input-id="t-min" class="w-full" :min="0" prefix="Rp " locale="id-ID" fluid /></FormField>
        <div class="flex justify-end gap-2 sm:col-span-2"><Button label="Batal" text severity="secondary" type="button" @click="terms = null" /><Button label="Simpan" type="submit" :loading="busy" /></div>
      </form>
    </Dialog>
  </div>
</template>
