<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Select from 'primevue/select'
import { useConfirm } from 'primevue/useconfirm'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { CreatedMerchant, Merchant, PlatformPlan } from '@/types/api'

/**
 * Konsol operator platform: membuat merchant baru (organisasi, outlet, kasir 1, akun pemilik),
 * mengganti paket, dan menangguhkan akses. Hanya untuk operator dengan izin platform.manage.
 */
const { busy, run } = useApiAction()
const confirm = useConfirm()
const merchants = ref<Merchant[]>([])
const plans = ref<PlatformPlan[]>([])

const TYPES = [
  { label: 'F&B (kafe, resto, warung)', value: 'FNB' },
  { label: 'Retail (toko, minimarket)', value: 'RETAIL' },
  { label: 'Fashion & merchandise (pakaian, sepatu, aksesoris)', value: 'FASHION' },
  { label: 'Jasa', value: 'SERVICE' },
  { label: 'Umum', value: 'GENERAL' },
]
const typeLabel = (v: string) => TYPES.find((t) => t.value === v)?.label.split(' (')[0] ?? v
const planOptions = computed(() => plans.value.map((p) => ({ label: `${p.name} · ${limitText(p)}`, value: p.code })))
const limit = (n?: number | null) => (n == null ? '∞' : String(n))
const limitText = (p: PlatformPlan) => `${limit(p.maxOutlets)} outlet, ${limit(p.maxUsers)} user, ${limit(p.maxProducts)} produk`
const planName = (code?: string | null) => plans.value.find((p) => p.code === code)?.name ?? code ?? 'Tanpa paket'
const dateText = (iso?: string | null) => (iso ? new Date(iso).toLocaleDateString('id-ID', { day: '2-digit', month: 'short', year: 'numeric' }) : '—')

async function load() {
  await run(async () => {
    const [m, p] = await Promise.all([api().get<Merchant[]>('/api/platform/merchants'), api().get<PlatformPlan[]>('/api/platform/plans')])
    merchants.value = m.data
    plans.value = p.data
  })
}
onMounted(load)

// ---- merchant baru
const open = ref(false)
const created = ref<CreatedMerchant | null>(null)
const blank = () => ({ code: '', name: '', businessType: 'FNB', plan: 'TRIAL', outletCode: '', outletName: '', ownerName: '', ownerEmail: '', ownerPassword: '' })
const form = reactive(blank())
const valid = computed(() =>
  /^[A-Za-z0-9_-]{2,24}$/.test(form.code) && form.name.trim() && /^[A-Za-z0-9_-]{2,32}$/.test(form.outletCode) && form.outletName.trim()
  && form.ownerName.trim() && /^\S+@\S+\.\S+$/.test(form.ownerEmail) && form.ownerPassword.length >= 10
  && /[A-Za-z]/.test(form.ownerPassword) && /\d/.test(form.ownerPassword))
function openCreate() {
  Object.assign(form, blank())
  open.value = true
}
function suggestOutlet() {
  if (!form.outletCode && form.code) form.outletCode = `${form.code.toUpperCase()}01`
}
async function create() {
  if (!valid.value) return
  const res = await run(() => api().post<CreatedMerchant>('/api/platform/merchants', { ...form, code: form.code.toUpperCase(), outletCode: form.outletCode.toUpperCase() }), 'Merchant dibuat')
  if (res) {
    open.value = false
    created.value = res.data
    await load()
  }
}

// ---- ganti paket
const planDialog = ref<Merchant | null>(null)
const newPlan = ref('')
function openPlan(m: Merchant) {
  planDialog.value = m
  newPlan.value = m.planCode ?? 'TRIAL'
}
async function savePlan() {
  if (!planDialog.value) return
  const ok = await run(() => api().put(`/api/platform/merchants/${planDialog.value!.id}/plan`, { plan: newPlan.value }), 'Paket diubah')
  if (ok) {
    planDialog.value = null
    await load()
  }
}

// ---- tangguhkan / aktifkan
function toggle(m: Merchant) {
  const doIt = async () => {
    const ok = await run(() => api().put(`/api/platform/merchants/${m.id}/active`, { active: !m.active, reason: m.active ? 'Ditangguhkan operator' : undefined }), m.active ? 'Merchant ditangguhkan' : 'Merchant diaktifkan')
    if (ok) await load()
  }
  if (!m.active) return void doIt()
  confirm.require({
    header: `Tangguhkan ${m.name}?`,
    message: 'Seluruh pengguna merchant langsung tidak bisa masuk atau bertransaksi sampai diaktifkan kembali. Data tidak dihapus.',
    acceptLabel: 'Tangguhkan', rejectLabel: 'Batal', acceptProps: { severity: 'danger' },
    accept: () => void doIt(),
  })
}
</script>

<template>
  <div>
    <PageHeader title="Merchant" description="Daftar bisnis yang memakai POS ini. Setiap merchant terisolasi penuh: data, pengguna, dan pengaturannya tidak terlihat oleh merchant lain.">
      <template #actions><Button label="Merchant baru" icon="pi pi-plus" @click="openCreate" /></template>
    </PageHeader>

    <DataTable :value="merchants" data-key="id" class="rounded-2xl border border-line bg-surface" :loading="busy && !merchants.length">
      <template #empty>Belum ada merchant. Buat yang pertama dengan tombol “Merchant baru”.</template>
      <Column header="Merchant">
        <template #body="{ data }">
          <div class="font-semibold">{{ data.name }}</div>
          <div class="text-xs text-ink-faint">{{ data.code }} · {{ typeLabel(data.businessType) }}</div>
        </template>
      </Column>
      <Column header="Paket">
        <template #body="{ data }">
          <div>{{ planName(data.planCode) }}</div>
          <div v-if="data.subStatus === 'TRIAL'" class="text-xs text-ink-faint">Trial s.d. {{ dateText(data.trialEndsAt) }}</div>
        </template>
      </Column>
      <Column header="Pemakaian">
        <template #body="{ data }"><span class="tabular text-sm">{{ data.outlets }} outlet · {{ data.terminals }} kasir · {{ data.users }} user · {{ data.products }} produk</span></template>
      </Column>
      <Column header="Transaksi terakhir"><template #body="{ data }">{{ dateText(data.lastSaleAt) }}</template></Column>
      <Column header="Status">
        <template #body="{ data }">
          <span :class="['inline-flex rounded-full px-2 py-0.5 text-xs font-medium', data.active ? 'bg-jade-50 text-jade-700' : 'bg-alert-50 text-alert-600']">{{ data.active ? 'Aktif' : 'Ditangguhkan' }}</span>
        </template>
      </Column>
      <Column class="w-40">
        <template #body="{ data }">
          <Button icon="pi pi-box" text rounded :aria-label="`Ganti paket ${data.name}`" v-tooltip.top="'Ganti paket'" @click="openPlan(data)" />
          <Button :icon="data.active ? 'pi pi-pause' : 'pi pi-play'" text rounded :severity="data.active ? 'danger' : 'success'"
            :aria-label="data.active ? `Tangguhkan ${data.name}` : `Aktifkan ${data.name}`" v-tooltip.top="data.active ? 'Tangguhkan' : 'Aktifkan'" @click="toggle(data)" />
        </template>
      </Column>
    </DataTable>

    <Dialog v-model:visible="open" header="Merchant baru" modal class="w-full max-w-2xl">
      <form class="grid gap-4 md:grid-cols-2" @submit.prevent="create">
        <FormField label="Nama bisnis" for="m-name" required><InputText id="m-name" v-model="form.name" class="w-full" maxlength="120" /></FormField>
        <FormField label="Kode merchant" for="m-code" required hint="Huruf/angka, jadi awalan nomor struk & username pemilik"><InputText id="m-code" v-model="form.code" class="w-full uppercase" maxlength="24" @blur="suggestOutlet" /></FormField>
        <FormField label="Jenis usaha" for="m-type"><Select v-model="form.businessType" input-id="m-type" :options="TYPES" option-label="label" option-value="value" class="w-full" /></FormField>
        <FormField label="Paket" for="m-plan"><Select v-model="form.plan" input-id="m-plan" :options="planOptions" option-label="label" option-value="value" class="w-full" /></FormField>
        <FormField label="Nama outlet pertama" for="m-oname" required><InputText id="m-oname" v-model="form.outletName" class="w-full" maxlength="120" /></FormField>
        <FormField label="Kode outlet" for="m-ocode" required><InputText id="m-ocode" v-model="form.outletCode" class="w-full uppercase" maxlength="32" /></FormField>
        <FormField label="Nama pemilik" for="m-owner" required><InputText id="m-owner" v-model="form.ownerName" class="w-full" maxlength="120" /></FormField>
        <FormField label="Email pemilik" for="m-email" required><InputText id="m-email" v-model="form.ownerEmail" type="email" class="w-full" autocomplete="off" /></FormField>
        <FormField label="Password awal" for="m-pass" required hint="Minimal 10 karakter, huruf dan angka. Pemilik diminta menggantinya." class="md:col-span-2">
          <Password v-model="form.ownerPassword" input-id="m-pass" class="w-full" fluid :feedback="false" toggle-mask autocomplete="new-password" />
        </FormField>
        <div class="flex justify-end gap-2 md:col-span-2">
          <Button label="Batal" text severity="secondary" type="button" @click="open = false" />
          <Button label="Buat merchant" type="submit" :loading="busy" :disabled="!valid" />
        </div>
      </form>
    </Dialog>

    <Dialog :visible="!!planDialog" header="Ganti paket" modal class="w-full max-w-md" @update:visible="planDialog = null">
      <form v-if="planDialog" class="space-y-4" @submit.prevent="savePlan">
        <p class="text-sm text-ink-soft">{{ planDialog.name }}. Batas baru berlaku untuk penambahan data berikutnya; data yang sudah ada tidak dihapus.</p>
        <FormField label="Paket" for="p-plan"><Select v-model="newPlan" input-id="p-plan" :options="planOptions" option-label="label" option-value="value" class="w-full" /></FormField>
        <div class="flex justify-end gap-2"><Button label="Batal" text severity="secondary" type="button" @click="planDialog = null" /><Button label="Simpan" type="submit" :loading="busy" /></div>
      </form>
    </Dialog>

    <Dialog :visible="!!created" header="Merchant siap dipakai" modal class="w-full max-w-md" @update:visible="created = null">
      <div v-if="created" class="space-y-3 text-sm">
        <p><strong>{{ created.merchant.name }}</strong> sudah dibuat lengkap dengan outlet, kasir 1, pajak, dan metode pembayaran awal.</p>
        <dl class="rounded-xl bg-field p-4">
          <dt class="text-xs text-ink-faint">Username pemilik</dt><dd class="font-mono font-semibold">{{ created.ownerUsername }}</dd>
          <dt class="mt-2 text-xs text-ink-faint">Email login</dt><dd class="font-semibold">{{ form.ownerEmail }}</dd>
        </dl>
        <p class="text-ink-soft">Sampaikan password awal ke pemilik lewat jalur aman. Password tidak ditampilkan lagi.</p>
        <div class="flex justify-end"><Button label="Selesai" @click="created = null" /></div>
      </div>
    </Dialog>
  </div>
</template>
