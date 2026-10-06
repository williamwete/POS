<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputNumber from 'primevue/inputnumber'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'
import Password from 'primevue/password'
import SelectButton from 'primevue/selectbutton'
import Textarea from 'primevue/textarea'
import { useSessionStore } from '@/stores/session'
import { useCashierStore } from '@/stores/cashier'
import { toReturnLines, useReturnStore } from '@/stores/returns'
import { useApiAction } from '@/composables/useApiAction'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'
import type { ReturnLookup, SaleReturn } from '@/types/api'
import { formatRupiah } from '@/utils/money'
import { formatDateTime } from '@/utils/format'
import ReturnPaper from './ReturnPaper.vue'

/**
 * Retur & refund (§28, §29). Kasir: cari struk → pilih barang & jumlah → retur dibuat (menunggu approval) →
 * supervisor menyetujui di terminal atau dari akunnya → refund. Nilai refund selalu dihitung server.
 */
const session = useSessionStore()
const cashier = useCashierStore()
const returns = useReturnStore()
const router = useRouter()
const { busy, run } = useApiAction()
// daftar dimuat dengan aksi terpisah agar tidak terlewati saat aksi lain sedang berjalan
const listAction = useApiAction()

const canCreate = computed(() => session.can('sale.create') && !!session.me?.employee)
const canApprove = computed(() => session.can('sale.refund'))
const canList = computed(() => canApprove.value || session.can('sale.view'))
const drawerOpen = computed(() => cashier.current?.status === 'OPEN')

onMounted(() => {
  if (!cashier.loaded) void run(() => cashier.load())
  void loadList()
})

// ---- 1. cari struk
const receiptNo = ref('')
const sale = ref<ReturnLookup | null>(null)
const qty = ref<Record<string, number | null>>({})
const reason = ref('')
const mode = ref<'CASH' | 'ORIGINAL'>('CASH')
const reference = ref('')
const current = ref<SaleReturn | null>(null)
let clientReturnId = ''

async function find() {
  const no = receiptNo.value.trim()
  if (!no) return
  const res = await run(() => returns.lookup(no))
  if (res) {
    sale.value = res
    qty.value = {}
    reason.value = ''
    mode.value = 'CASH'
    reference.value = ''
    current.value = null
    clientReturnId = newIdempotencyKey('ret')
  }
}

const remaining = computed(() =>
  Object.fromEntries((sale.value?.items ?? []).map((i) => [i.saleItemId, Number(i.remainingQuantity)])),
)
const lines = computed(() => toReturnLines(qty.value, remaining.value))
const hasNonCash = computed(() => (sale.value?.payments ?? []).some((p) => p.methodKind !== 'CASH'))
/** Perkiraan saja — server menghitung nilai bersih (setelah diskon) dan sisa terakhir per baris. */
const estimate = computed(() =>
  lines.value.reduce((sum, l) => {
    const i = sale.value!.items.find((x) => x.saleItemId === l.saleItemId)!
    const rem = Number(i.remainingQuantity)
    return sum + (l.quantity >= rem ? Number(i.remainingAmount) : Math.round((Number(i.netAmount) * l.quantity) / Number(i.quantity)))
  }, 0),
)
const canSubmit = computed(() =>
  !!sale.value?.returnable && lines.value.length > 0 && reason.value.trim().length >= 3
  && (mode.value === 'CASH' || !hasNonCash.value || reference.value.trim().length >= 3),
)

const MODES = [
  { value: 'CASH', label: 'Tunai dari laci' },
  { value: 'ORIGINAL', label: 'Ke metode bayar asal' },
]

async function submit() {
  if (!sale.value || !canSubmit.value) return
  const res = await run((key) => returns.create({
    clientReturnId,
    originalSaleId: sale.value!.saleId,
    reason: reason.value.trim(),
    refundMode: mode.value,
    refundReference: mode.value === 'ORIGINAL' ? reference.value.trim() || null : null,
    items: lines.value,
  }, key), 'Retur dibuat')
  if (res) {
    current.value = res
    void loadList()
  }
}

// ---- 2. approval di terminal
const approveOpen = ref(false)
const email = ref('')
const password = ref('')
const approveError = ref<string | null>(null)
const approving = ref(false)
watch(approveOpen, (v) => {
  if (v) {
    email.value = ''
    password.value = ''
    approveError.value = null
  }
})

async function approveAtTerminal() {
  if (!current.value || !email.value || !password.value) return
  approving.value = true
  approveError.value = null
  const pwd = password.value
  password.value = ''
  try {
    current.value = await returns.approveAtTerminal(current.value.id, email.value.trim(), pwd,
      current.value.refundMode === 'ORIGINAL' ? reference.value.trim() || null : null)
    approveOpen.value = false
    void cashier.load()
    void loadList()
  } catch (e) {
    approveError.value = e instanceof ApiError ? e.message : 'Persetujuan gagal.'
  } finally {
    approving.value = false
  }
}

// ---- tolak / batalkan
const rejectTarget = ref<SaleReturn | null>(null)
const rejectReason = ref('')
function openReject(r: SaleReturn) {
  rejectTarget.value = r
  rejectReason.value = ''
}
async function submitReject() {
  const r = rejectTarget.value
  if (!r) return
  const res = await run((key) => returns.reject(r.id, rejectReason.value.trim(), key), 'Retur ditolak')
  if (res) {
    if (current.value?.id === res.id) current.value = res
    rejectTarget.value = null
    void loadList()
  }
}

// ---- 3. daftar retur outlet (approver/supervisor)
const list = ref<SaleReturn[]>([])
async function loadList() {
  if (!canList.value || !session.outletId) return
  const res = await listAction.run(() => returns.list(session.outletId!))
  if (res) list.value = res
}
const pending = computed(() => list.value.filter((r) => r.status === 'PENDING_APPROVAL'))
const done = computed(() => list.value.filter((r) => r.status !== 'PENDING_APPROVAL'))
const isMine = (r: SaleReturn) => r.createdByName === session.me?.user.username

async function approveFromAccount(r: SaleReturn) {
  const res = await run((key) => returns.approve(r.id, r.refundReference ?? null, key), 'Refund disetujui')
  if (res) void loadList()
}

// ---- cetak bukti retur
const printTarget = ref<SaleReturn | null>(null)
async function printSlip(r: SaleReturn) {
  // daftar tidak memuat baris & refund: ambil detail lengkap dulu
  const full = r.items?.length ? r : await run(() => returns.get(r.id))
  if (!full) return
  printTarget.value = full
  await nextTick()
  window.print()
}

const cashRefund = (r: SaleReturn) => r.refunds.filter((f) => f.refundMethod === 'CASH').reduce((s, f) => s + Number(f.refundAmount), 0)
const STATUS: Record<string, { label: string; cls: string }> = {
  PENDING_APPROVAL: { label: 'Menunggu persetujuan', cls: 'bg-amber-100 text-amber-700' },
  COMPLETED: { label: 'Selesai', cls: 'bg-jade-50 text-jade-700' },
  REJECTED: { label: 'Ditolak', cls: 'bg-alert-50 text-alert-600' },
}
const qtyFmt = (n: number) => (Number.isInteger(Number(n)) ? String(Number(n)) : Number(n).toLocaleString('id-ID', { maximumFractionDigits: 3 }))
</script>

<template>
  <div class="mx-auto max-w-5xl">
    <div>
      <h1 class="text-2xl font-bold">Retur & refund</h1>
      <p class="mt-1 text-ink-soft">Retur selalu merujuk struk asli; struk asli tidak berubah. Refund perlu persetujuan supervisor.</p>
    </div>

    <!-- retur baru -->
    <section v-if="canCreate" class="mt-6 rounded-2xl border border-line bg-surface p-5" aria-labelledby="new-ret">
      <h2 id="new-ret" class="font-semibold">Retur baru</h2>
      <Message v-if="!drawerOpen" severity="warn" :closable="false" class="mt-3">
        Buka kasir (dan buka kunci terminal) dulu — refund tunai keluar dari laci Anda.
        <Button v-if="!cashier.current" label="Buka kasir" size="small" text @click="router.push({ name: 'cashier-open' })" />
      </Message>
      <form class="mt-3 flex flex-wrap gap-2" @submit.prevent="find">
        <InputText v-model="receiptNo" placeholder="Scan / ketik nomor struk, mis. POS-JKT-01-20261002-000001"
          class="min-w-0 flex-1 tabular" aria-label="Nomor struk" :disabled="!drawerOpen" />
        <Button type="submit" label="Cari struk" icon="pi pi-search" :loading="busy" :disabled="!drawerOpen || !receiptNo.trim()" />
      </form>

      <template v-if="sale && !current">
        <div class="mt-5 flex flex-wrap items-baseline justify-between gap-2 border-t border-line pt-4">
          <div>
            <div class="tabular font-semibold">{{ sale.receiptNo }}</div>
            <div class="text-sm text-ink-soft">{{ formatDateTime(sale.paidAt) }} · kasir {{ sale.cashierName }}</div>
          </div>
          <div class="tabular text-lg font-bold">{{ formatRupiah(sale.grandTotal) }}</div>
        </div>
        <Message v-if="!sale.returnable" severity="error" :closable="false" class="mt-3">
          Transaksi ini belum lunas atau sudah dibatalkan, tidak bisa diretur.
        </Message>

        <table class="mt-4 w-full text-sm">
          <thead class="text-left text-xs text-ink-soft">
            <tr>
              <th class="py-2 font-medium">Barang</th>
              <th class="py-2 text-right font-medium">Dibeli</th>
              <th class="py-2 text-right font-medium">Sudah diretur</th>
              <th class="w-40 py-2 text-right font-medium">Jumlah retur</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="i in sale.items" :key="i.saleItemId" class="border-t border-line">
              <td class="py-2">
                <div class="font-medium">{{ i.productName }}</div>
                <div class="tabular text-xs text-ink-soft">{{ i.sku }} · {{ formatRupiah(i.netAmount) }}</div>
              </td>
              <td class="tabular py-2 text-right">{{ qtyFmt(i.quantity) }} {{ i.uom }}</td>
              <td class="tabular py-2 text-right text-ink-soft">{{ qtyFmt(i.returnedQuantity) }}</td>
              <td class="py-2 text-right">
                <InputNumber v-model="qty[i.saleItemId]" :min="0" :max="Number(i.remainingQuantity)" show-buttons
                  button-layout="horizontal" :max-fraction-digits="3" :disabled="Number(i.remainingQuantity) <= 0"
                  input-class="w-14 text-center tabular" :aria-label="`Jumlah retur ${i.productName}`" />
                <div class="mt-1 text-xs text-ink-faint">sisa {{ qtyFmt(i.remainingQuantity) }}</div>
              </td>
            </tr>
          </tbody>
        </table>

        <div class="mt-5 grid gap-4 md:grid-cols-2">
          <div>
            <label for="ret-reason" class="mb-1 block text-sm font-medium">Alasan retur</label>
            <Textarea id="ret-reason" v-model="reason" rows="2" maxlength="500" class="w-full" placeholder="Mis. kemasan rusak, salah ukuran" />
          </div>
          <div class="space-y-3">
            <div>
              <span class="mb-1 block text-sm font-medium">Refund</span>
              <SelectButton v-model="mode" :options="hasNonCash ? MODES : MODES.slice(0, 1)" option-label="label"
                option-value="value" :allow-empty="false" aria-label="Metode refund" />
            </div>
            <div v-if="mode === 'ORIGINAL' && hasNonCash">
              <label for="ret-ref" class="mb-1 block text-sm font-medium">No. referensi refund non-tunai</label>
              <InputText id="ret-ref" v-model="reference" class="w-full" placeholder="Mis. no. void EDC / refund QRIS" />
            </div>
          </div>
        </div>
        <div class="mt-5 flex flex-wrap items-center justify-between gap-3">
          <span class="text-sm text-ink-soft">Perkiraan refund <strong class="tabular text-ink">{{ formatRupiah(estimate) }}</strong></span>
          <Button label="Buat retur" icon="pi pi-replay" :loading="busy" :disabled="!canSubmit" @click="submit" />
        </div>
      </template>

      <!-- retur yang baru dibuat -->
      <div v-if="current" class="mt-5 rounded-lg border border-line p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div class="tabular font-semibold">{{ current.returnNo }}</div>
            <div class="text-sm text-ink-soft">dari {{ current.originalReceiptNo }} · {{ current.items.length }} barang</div>
          </div>
          <span :class="['rounded-full px-2 py-0.5 text-xs font-medium', STATUS[current.status]!.cls]">{{ STATUS[current.status]!.label }}</span>
        </div>
        <div class="tabular mt-3 text-2xl font-bold">{{ formatRupiah(current.totalAmount) }}</div>
        <template v-if="current.status === 'PENDING_APPROVAL'">
          <p class="mt-2 text-sm text-ink-soft">Minta supervisor menyetujui di terminal ini, atau dari akunnya sendiri (menu Retur).</p>
          <div class="mt-3 flex flex-wrap gap-2">
            <Button label="Setujui di terminal" icon="pi pi-user-plus" @click="approveOpen = true" />
            <Button label="Batalkan retur" severity="secondary" text @click="openReject(current)" />
            <Button label="Muat ulang" icon="pi pi-refresh" severity="secondary" text @click="run(async () => (current = await returns.get(current!.id)))" />
          </div>
        </template>
        <template v-else-if="current.status === 'COMPLETED'">
          <Message v-if="cashRefund(current) > 0" severity="success" :closable="false" class="mt-3">
            Serahkan uang tunai <strong class="tabular">{{ formatRupiah(cashRefund(current)) }}</strong> kepada pelanggan.
          </Message>
          <ul class="mt-2 text-sm">
            <li v-for="f in current.refunds" :key="f.id" class="flex justify-between border-t border-line py-1">
              <span>{{ f.refundMethod }}<template v-if="f.referenceNumber"> · {{ f.referenceNumber }}</template></span>
              <span class="tabular">{{ formatRupiah(f.refundAmount) }}</span>
            </li>
          </ul>
          <p class="mt-2 text-xs text-ink-soft">Disetujui {{ current.approvedByName }}</p>
          <div class="mt-3 flex gap-2">
            <Button label="Cetak bukti retur" icon="pi pi-print" severity="secondary" @click="printSlip(current)" />
            <Button label="Retur lain" text @click="sale = null; current = null; receiptNo = ''" />
          </div>
        </template>
        <p v-else class="mt-2 text-sm text-alert-600">Ditolak: {{ current.rejectReason }}</p>
      </div>
    </section>

    <!-- menunggu persetujuan & riwayat (supervisor) -->
    <section v-if="canList" class="mt-6 rounded-2xl border border-line bg-surface p-5" aria-labelledby="pending-ret">
      <div class="flex items-center justify-between gap-2">
        <h2 id="pending-ret" class="font-semibold">Menunggu persetujuan <span class="tabular text-ink-soft">({{ pending.length }})</span></h2>
        <Button icon="pi pi-refresh" text severity="secondary" aria-label="Muat ulang" @click="loadList" />
      </div>
      <ul class="mt-3 divide-y divide-line">
        <li v-for="r in pending" :key="r.id" class="flex flex-wrap items-center justify-between gap-3 py-3">
          <div class="min-w-0">
            <div class="tabular font-medium">{{ r.returnNo }} <span class="text-ink-soft">· {{ r.originalReceiptNo }}</span></div>
            <div class="text-sm text-ink-soft">{{ r.createdByName }} · {{ r.reason }}</div>
          </div>
          <div class="flex items-center gap-2">
            <span class="tabular font-semibold">{{ formatRupiah(r.totalAmount) }}</span>
            <Button v-if="canApprove && !isMine(r)" label="Setujui" size="small" :loading="busy" @click="approveFromAccount(r)" />
            <Button label="Tolak" size="small" severity="secondary" text @click="openReject(r)" />
          </div>
        </li>
        <li v-if="!pending.length" class="py-3 text-sm text-ink-soft">Tidak ada retur yang menunggu.</li>
      </ul>
      <h3 class="mt-5 text-sm font-semibold text-ink-soft">Retur hari ini</h3>
      <ul class="mt-2 divide-y divide-line text-sm">
        <li v-for="r in done" :key="r.id" class="flex flex-wrap items-center justify-between gap-2 py-2">
          <span class="tabular">{{ r.returnNo }} <span class="text-ink-soft">· {{ r.originalReceiptNo }}</span></span>
          <span class="flex items-center gap-2">
            <span :class="['rounded-full px-2 py-0.5 text-xs font-medium', STATUS[r.status]!.cls]">{{ STATUS[r.status]!.label }}</span>
            <span class="tabular font-semibold">{{ formatRupiah(r.totalAmount) }}</span>
            <Button v-if="r.status === 'COMPLETED'" icon="pi pi-print" text size="small" aria-label="Cetak bukti retur" @click="printSlip(r)" />
          </span>
        </li>
        <li v-if="!done.length" class="py-2 text-ink-soft">Belum ada.</li>
      </ul>
    </section>

    <Dialog v-model:visible="approveOpen" modal header="Persetujuan refund" class="w-full max-w-md">
      <form class="space-y-4" autocomplete="off" @submit.prevent="approveAtTerminal">
        <div class="rounded-md bg-amber-100 p-3 text-sm">
          <div class="font-semibold">Refund · <span class="tabular">{{ formatRupiah(current?.totalAmount) }}</span></div>
          <div class="mt-1 text-ink-soft">{{ current?.returnNo }} · {{ current?.reason }}</div>
        </div>
        <p class="text-sm text-ink-soft">Supervisor memasukkan akunnya sendiri. Persetujuan tercatat atas nama approver.</p>
        <Message v-if="approveError" severity="error" :closable="false">{{ approveError }}</Message>
        <div>
          <label for="ret-approver-email" class="mb-1 block text-sm font-medium">Email approver</label>
          <InputText id="ret-approver-email" v-model="email" type="email" class="w-full" autocomplete="off" />
        </div>
        <div>
          <label for="ret-approver-password" class="mb-1 block text-sm font-medium">Password approver</label>
          <Password v-model="password" input-id="ret-approver-password" :feedback="false" toggle-mask class="w-full"
            input-class="w-full" autocomplete="new-password" />
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="approveOpen = false" />
          <Button label="Setujui refund" icon="pi pi-check" type="submit" :loading="approving" :disabled="!email || !password" />
        </div>
      </form>
    </Dialog>

    <Dialog :visible="!!rejectTarget" modal header="Tolak retur" class="w-full max-w-md" @update:visible="(v) => { if (!v) rejectTarget = null }">
      <form class="space-y-4" @submit.prevent="submitReject">
        <p class="text-sm text-ink-soft">{{ rejectTarget?.returnNo }} tidak diproses; jumlah barang kembali bisa diretur.</p>
        <div>
          <label for="rej-reason" class="mb-1 block text-sm font-medium">Alasan</label>
          <Textarea id="rej-reason" v-model="rejectReason" rows="2" maxlength="500" class="w-full" />
          <p class="mt-1 text-xs text-ink-faint">Minimal 5 karakter.</p>
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Kembali" text severity="secondary" type="button" @click="rejectTarget = null" />
          <Button label="Tolak retur" severity="danger" type="submit" :loading="busy" :disabled="rejectReason.trim().length < 5" />
        </div>
      </form>
    </Dialog>

    <div v-if="printTarget" class="receipt-print print-only" aria-hidden="true">
      <ReturnPaper :ret="printTarget" :organization-name="session.me?.organization.name" :outlet-name="session.currentOutlet?.name" />
    </div>
  </div>
</template>

<style scoped>
.print-only {
  display: none;
}
@media print {
  .print-only {
    display: block;
  }
}
</style>
