<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import ToggleSwitch from 'primevue/toggleswitch'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import ReceiptPaper from '@/modules/pos/ReceiptPaper.vue'
import BrandSettings from './BrandSettings.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Receipt, ReceiptProfile } from '@/types/api'

const session = useSessionStore()
const { busy, run } = useApiAction()
const ALL = '__all__'
const profiles = ref<ReceiptProfile[]>([])

const scopeOptions = computed(() => {
  const opts = session.outlets.filter((o) => session.can('receipt.manage', o.id)).map((o) => ({ label: `${o.code} ${o.name}`, value: o.id as string }))
  if (session.can('receipt.manage', 'org')) opts.unshift({ label: 'Semua outlet (bawaan)', value: ALL })
  return opts
})
const canManage = computed(() => scopeOptions.value.length > 0)
const scope = ref<string>(ALL)
const scopeId = computed(() => (scope.value === ALL ? null : scope.value))

const form = reactive<ReceiptProfile>({ businessName: '', address: '', phone: '', headerText: '', footerText: '', taxId: '', showTaxDetail: true, showCashier: true, paperWidthMm: 80 })

function fill() {
  const p = profiles.value.find((x) => (x.outletId ?? null) === scopeId.value)
  Object.assign(form, {
    businessName: p?.businessName ?? '', address: p?.address ?? '', phone: p?.phone ?? '', headerText: p?.headerText ?? '',
    footerText: p?.footerText ?? '', taxId: p?.taxId ?? '', showTaxDetail: p?.showTaxDetail ?? true,
    showCashier: p?.showCashier ?? true, paperWidthMm: p?.paperWidthMm ?? 80,
  })
}

async function load() {
  await run(async () => { profiles.value = (await api().get<ReceiptProfile[]>('/api/catalog/receipt-profiles')).data })
  fill()
}
onMounted(async () => { scope.value = scopeOptions.value[0]?.value ?? ALL; await load() })
watch(scope, fill)

async function save() {
  const ok = await run(() => api().put<ReceiptProfile[]>('/api/catalog/receipt-profiles', { outletId: scopeId.value, ...form }), 'Pengaturan struk disimpan')
  if (ok) { profiles.value = ok.data; fill() }
}

// Contoh struk agar perubahan langsung terlihat.
const sample = computed<Receipt>(() => ({
  saleId: 'sample', receiptNo: 'T-0001-20260101-000001', status: 'PAID',
  organizationName: form.businessName || session.me?.organization?.name || 'Nama Usaha', outletName: session.outlets.find((o) => o.id === (scopeId.value ?? session.outletId))?.name ?? 'Outlet',
  outletAddress: form.address || undefined, outletPhone: form.phone || undefined, terminalCode: 'KASIR-1', cashierName: 'Contoh Kasir',
  businessDate: '2026-01-01', issuedAt: new Date().toISOString(), pricesIncludeTax: true,
  lines: [
    { name: 'Mie Ayam', sku: 'MIE', quantity: 2, uom: 'PORSI', unitPrice: 29000, listPrice: 29000, discount: 0, amount: 58000, taxRate: 10, options: 'Pedas, Bakso' },
    { name: 'Es Teh', sku: 'TEH', quantity: 1, uom: 'GLS', unitPrice: 6000, listPrice: 6000, discount: 0, amount: 6000, taxRate: 10, options: null },
  ],
  itemCount: 3, subtotal: 64000, discountTotal: 0, taxTotal: 5818, grandTotal: 64000,
  payments: [{ methodName: 'Tunai', methodKind: 'CASH', amount: 64000, amountReceived: 70000, changeAmount: 6000 }],
  paidAmount: 64000, changeAmount: 6000, printCount: 1, headerText: form.headerText || null, footerText: form.footerText || null,
  taxId: form.taxId || null, showTaxDetail: form.showTaxDetail, showCashier: form.showCashier, paperWidthMm: form.paperWidthMm,
}))
</script>

<template>
  <div>
    <PageHeader title="Manage Receipt" description="Atur nama usaha, alamat, dan catatan di struk. Pengaturan outlet menimpa pengaturan bawaan semua outlet." />
    <p v-if="!canManage" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">Anda tidak punya izin mengatur struk.</p>
    <template v-else>
    <BrandSettings v-if="session.can('receipt.manage', 'org')" />
    <div class="grid gap-8 lg:grid-cols-[1fr_auto]">
      <form class="grid max-w-2xl gap-4 sm:grid-cols-2" @submit.prevent="save">
        <FormField label="Berlaku untuk" for="r-scope" class="sm:col-span-2"><Select v-model="scope" input-id="r-scope" :options="scopeOptions" option-label="label" option-value="value" class="w-full" /></FormField>
        <FormField label="Nama usaha di struk" for="r-name" class="sm:col-span-2"><InputText id="r-name" v-model="form.businessName" class="w-full" maxlength="80" placeholder="Kosong = nama organisasi" /></FormField>
        <FormField label="Alamat" for="r-addr" class="sm:col-span-2"><Textarea id="r-addr" v-model="form.address" class="w-full" rows="2" maxlength="200" placeholder="Kosong = alamat outlet" auto-resize /></FormField>
        <FormField label="Telepon" for="r-phone"><InputText id="r-phone" v-model="form.phone" class="w-full" maxlength="30" /></FormField>
        <FormField label="NPWP / ID pajak" for="r-tax"><InputText id="r-tax" v-model="form.taxId" class="w-full" maxlength="40" /></FormField>
        <FormField label="Teks di atas (header)" for="r-head" class="sm:col-span-2"><InputText id="r-head" v-model="form.headerText" class="w-full" maxlength="200" placeholder="Mis. Buka setiap hari 08.00–21.00" /></FormField>
        <FormField label="Teks di bawah (footer)" for="r-foot" class="sm:col-span-2"><InputText id="r-foot" v-model="form.footerText" class="w-full" maxlength="200" placeholder="Mis. Terima kasih, sampai jumpa lagi" /></FormField>
        <FormField label="Lebar kertas" for="r-paper"><SelectButton v-model="form.paperWidthMm" :options="[{ l: '58 mm', v: 58 }, { l: '80 mm', v: 80 }]" option-label="l" option-value="v" :allow-empty="false" aria-labelledby="r-paper" /></FormField>
        <div class="flex flex-col justify-end gap-3">
          <label class="flex items-center gap-3 text-sm"><ToggleSwitch v-model="form.showTaxDetail" /> Tampilkan rincian pajak</label>
          <label class="flex items-center gap-3 text-sm"><ToggleSwitch v-model="form.showCashier" /> Tampilkan nama kasir</label>
        </div>
        <div class="flex justify-end pt-2 sm:col-span-2"><Button label="Simpan pengaturan" type="submit" :loading="busy" /></div>
      </form>
      <aside aria-label="Contoh struk" class="rounded-2xl border border-line bg-field p-4"><ReceiptPaper :receipt="sample" /></aside>
    </div>
    </template>
  </div>
</template>
