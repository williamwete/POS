<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Button from 'primevue/button'
import Drawer from 'primevue/drawer'
import Dialog from 'primevue/dialog'
import InputNumber from 'primevue/inputnumber'
import SelectButton from 'primevue/selectbutton'
import Textarea from 'primevue/textarea'
import { useRouter } from 'vue-router'
import { useCashierStore } from '@/stores/cashier'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { CashCount, CashierSession, CashMovement, SessionTransaction } from '@/types/api'
import ShiftReportDialog from './ShiftReportDialog.vue'
import { formatDateTime } from '@/utils/format'
import { formatNumber, formatRupiah } from '@/utils/money'
import { clockTime } from '@/modules/attendance/attendanceFormat'
import {
  COUNT_TYPE_LABEL, DIFFERENCE_REASON_LABEL, LOCK_REASON_LABEL, MOVEMENT_TYPE_LABEL, SESSION_STATUS_CLASS,
  SESSION_STATUS_LABEL, signedRupiah,
} from './cashierFormat'

const session = useSessionStore()
const cashier = useCashierStore()
const router = useRouter()
const { busy, run } = useApiAction()

const outlets = computed(() => session.outlets.filter((o) => session.can('cashier.view', o.id)))
const outletId = ref<string | null>(outlets.value.find((o) => o.id === session.outletId)?.id ?? outlets.value[0]?.id ?? null)
const date = ref<Date | null>(null)
const rows = ref<CashierSession[]>([])
const loading = ref(false)
const detail = ref<CashierSession | null>(null)

const activeCount = computed(() => rows.value.filter((r) => ['OPEN', 'ON_BREAK', 'CLOSING'].includes(r.status)).length)

function ymd(d: Date) {
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

async function load() {
  if (!outletId.value) return
  loading.value = true
  await run(async () => {
    rows.value = (await api().get<CashierSession[]>('/api/cashier/sessions', {
      query: { outletId: outletId.value, businessDate: date.value ? ymd(date.value) : undefined },
    })).data
  })
  loading.value = false
}
watch([outletId, date], load)
onMounted(load)

const movements = ref<CashMovement[]>([])
const txs = ref<SessionTransaction[]>([])
const reportType = ref<'X' | 'Z'>('X')
const reportOpen = ref(false)
function openReport(t: 'X' | 'Z') {
  reportType.value = t
  reportOpen.value = true
}

async function openDetail(row: CashierSession) {
  await run(async () => {
    const [d, m, t] = await Promise.all([cashier.get(row.id), cashier.movements(row.id), cashier.transactions(row.id)])
    detail.value = d
    movements.value = m
    txs.value = t
  })
}

const STATUS_TX: Record<string, string> = {
  PAID: 'Lunas', POSTING: 'Lunas', POSTED: 'Lunas', SYNC_ERROR: 'Lunas', RETURNED: 'Diretur', VOID: 'Void',
  HELD: 'Ditahan', CHECKOUT: 'Belum dibayar', PAYMENT_PENDING: 'Menunggu bayar',
}

const isActive = (x: CashierSession) => ['OPEN', 'ON_BREAK'].includes(x.status)
const isMine = (x: CashierSession) => x.employeeId === session.me?.employee?.id
const canAdjust = computed(() => !!detail.value && isActive(detail.value) && !isMine(detail.value)
  && session.can('cash.cash_adjustment', detail.value.outletId))
const canCloseOther = computed(() => !!detail.value && isActive(detail.value) && !isMine(detail.value)
  && session.can('cashier.close', detail.value.outletId) && session.can('cash.approve_difference', detail.value.outletId))

// ---- penyesuaian kas (restricted)
const adjustOpen = ref(false)
const adjustDir = ref<1 | -1>(1)
const adjustAmount = ref<number | null>(null)
const adjustReason = ref('')
function openAdjust() {
  adjustDir.value = 1
  adjustAmount.value = null
  adjustReason.value = ''
  adjustOpen.value = true
}
async function submitAdjust() {
  const d = detail.value
  if (!d || !adjustAmount.value) return
  const ok = await run((key) => cashier.adjustment(d.id, adjustDir.value * adjustAmount.value!, adjustReason.value.trim(), key),
    'Penyesuaian kas tercatat')
  if (ok) {
    adjustOpen.value = false
    await openDetail(d)
    await load()
  }
}

function lastCount(s: CashierSession): CashCount | null {
  return s.counts.length ? s.counts[s.counts.length - 1]! : null
}

function diffClass(n?: number | null) {
  if (n === null || n === undefined) return 'text-ink-faint'
  const v = Number(n)
  return v === 0 ? 'text-jade-700' : 'text-alert-600 font-semibold'
}

const signed = signedRupiah
</script>

<template>
  <div>
    <PageHeader title="Sesi kasir" description="Laci kas yang dibuka di outlet ini: siapa memegang terminal mana, modal awal, dan hasil hitungan.">
      <template #actions>
        <Select v-model="outletId" :options="outlets" option-label="name" option-value="id" class="min-w-52" aria-label="Outlet" />
        <DatePicker v-model="date" date-format="dd/mm/yy" placeholder="Business date hari ini" show-icon show-button-bar aria-label="Business date" />
        <Button icon="pi pi-refresh" severity="secondary" text aria-label="Muat ulang" @click="load" />
      </template>
    </PageHeader>

    <p class="mb-3 text-sm text-ink-soft">
      <span class="tabular font-semibold text-ink">{{ activeCount }}</span> kasir aktif,
      <span class="tabular font-semibold text-ink">{{ rows.length }}</span> session ditampilkan.
    </p>

    <DataTable
      :value="rows"
      :loading="loading"
      data-key="id"
      class="rounded-2xl border border-line bg-surface"
      row-hover
      @row-click="(e) => openDetail(e.data as CashierSession)"
    >
      <template #empty>Belum ada kasir yang dibuka pada business date ini.</template>
      <Column header="Terminal">
        <template #body="{ data }">
          <span class="tabular font-bold">{{ data.terminalCode }}</span>
          <div class="text-xs text-ink-soft">{{ data.terminalName }}</div>
        </template>
      </Column>
      <Column header="Kasir">
        <template #body="{ data }">
          <div class="font-semibold">{{ data.employeeName }}</div>
          <div class="tabular text-xs text-ink-soft">{{ data.employeeCode }}</div>
        </template>
      </Column>
      <Column header="Dibuka"><template #body="{ data }"><span class="tabular">{{ clockTime(data.openedAt) }}</span></template></Column>
      <Column header="Modal awal" class="text-right">
        <template #body="{ data }"><span class="tabular">{{ formatRupiah(data.openingCash) }}</span></template>
      </Column>
      <Column header="Kas seharusnya" class="text-right">
        <template #body="{ data }"><span class="tabular font-semibold">{{ formatRupiah(data.expectedCash) }}</span></template>
      </Column>
      <Column header="Status">
        <template #body="{ data }">
          <span :class="['rounded-full px-2 py-0.5 text-xs font-medium', SESSION_STATUS_CLASS[data.status as keyof typeof SESSION_STATUS_CLASS]]">
            {{ SESSION_STATUS_LABEL[data.status as keyof typeof SESSION_STATUS_LABEL] }}
          </span>
          <div v-if="data.lockReason" class="mt-1 text-xs text-ink-soft">
            {{ LOCK_REASON_LABEL[data.lockReason as keyof typeof LOCK_REASON_LABEL] }}
          </div>
        </template>
      </Column>
      <Column class="w-12"><template #body><i class="pi pi-chevron-right text-ink-faint" aria-hidden="true" /></template></Column>
    </DataTable>

    <Drawer
      :visible="!!detail"
      position="right"
      :header="detail ? `${detail.terminalCode} · ${detail.employeeName}` : ''"
      :style="{ width: 'min(100vw, 34rem)' }"
      @update:visible="(v) => { if (!v) detail = null }"
    >
      <template v-if="detail">
        <dl class="grid grid-cols-2 gap-px overflow-hidden rounded-lg border border-line bg-line text-sm">
          <div class="bg-surface p-3"><dt class="text-xs text-ink-soft">Dibuka</dt><dd class="tabular font-semibold">{{ formatDateTime(detail.openedAt) }}</dd></div>
          <div class="bg-surface p-3"><dt class="text-xs text-ink-soft">Status</dt><dd class="font-semibold">{{ SESSION_STATUS_LABEL[detail.status] }}</dd></div>
          <div class="bg-surface p-3"><dt class="text-xs text-ink-soft">Modal awal</dt><dd class="tabular font-semibold">{{ formatRupiah(detail.openingCash) }}</dd></div>
          <div class="bg-amber-100 p-3"><dt class="text-xs text-amber-700">Kas seharusnya</dt><dd class="tabular font-semibold">{{ formatRupiah(detail.expectedCash) }}</dd></div>
        </dl>
        <p v-if="detail.cancelReason" class="mt-3 rounded-md bg-alert-50 p-3 text-sm text-alert-600">Dibatalkan: {{ detail.cancelReason }}</p>

        <div v-if="detail.status === 'CLOSED'" class="mt-3 rounded-lg border border-line p-3 text-sm">
          <div class="flex items-baseline justify-between gap-2">
            <span class="font-semibold">Tutup kasir</span>
            <span class="tabular text-xs text-ink-soft">{{ formatDateTime(detail.closedAt) }} · {{ detail.closedByName }}</span>
          </div>
          <div class="mt-2 grid grid-cols-2 gap-2">
            <div><div class="text-xs text-ink-soft">Uang dihitung</div><div class="tabular font-semibold">{{ formatRupiah(detail.closingCash) }}</div></div>
            <div><div class="text-xs text-ink-soft">Selisih</div><div :class="['tabular', diffClass(detail.difference)]">{{ signedRupiah(detail.difference) }}</div></div>
          </div>
          <p v-if="detail.differenceReason" class="mt-2 text-xs text-ink-soft">
            {{ DIFFERENCE_REASON_LABEL[detail.differenceReason] }}<template v-if="detail.differenceNote"> — {{ detail.differenceNote }}</template>
            <template v-if="detail.differenceApprovedByName"> · disetujui {{ detail.differenceApprovedByName }}</template>
          </p>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <Button v-if="isActive(detail)" label="X report" icon="pi pi-file" severity="secondary" size="small" @click="openReport('X')" />
          <Button v-if="detail.status === 'CLOSED'" label="Z report" icon="pi pi-print" severity="secondary" size="small" @click="openReport('Z')" />
          <Button v-if="canAdjust" label="Penyesuaian kas" icon="pi pi-sliders-h" severity="secondary" size="small" @click="openAdjust" />
          <Button v-if="canCloseOther" label="Tutup laci ini" icon="pi pi-power-off" severity="danger" outlined size="small"
            @click="router.push({ name: 'cashier-close', query: { session: detail.id } })" />
        </div>

        <h3 class="mt-6 text-sm font-semibold text-ink-soft">Transaksi ({{ txs.length }})</h3>
        <ul class="mt-2 max-h-80 divide-y divide-line overflow-auto rounded-lg border border-line text-sm">
          <li v-for="t in txs" :key="t.id" class="flex items-start justify-between gap-3 p-3">
            <div class="min-w-0">
              <div class="tabular font-medium">{{ t.receiptNo ?? '—' }}</div>
              <div class="text-xs text-ink-soft">
                {{ clockTime(t.time) }} · {{ STATUS_TX[t.status] ?? t.status }}<template v-if="t.paymentMethods"> · {{ t.paymentMethods }}</template>
              </div>
              <div v-if="t.voidReason" class="truncate text-xs text-alert-600">{{ t.voidReason }}</div>
            </div>
            <span :class="['tabular whitespace-nowrap font-semibold', t.status === 'VOID' ? 'text-ink-faint line-through' : '']">{{ formatRupiah(t.grandTotal) }}</span>
          </li>
          <li v-if="!txs.length" class="p-3 text-ink-soft">Belum ada transaksi.</li>
        </ul>

        <h3 class="mt-6 text-sm font-semibold text-ink-soft">Mutasi kas</h3>
        <ul class="mt-2 divide-y divide-line rounded-lg border border-line text-sm">
          <li v-for="m in movements" :key="m.id" class="flex items-start justify-between gap-3 p-3">
            <div class="min-w-0">
              <div class="font-medium">{{ MOVEMENT_TYPE_LABEL[m.movementType] ?? m.movementType }}</div>
              <div v-if="m.reason" class="truncate text-xs text-ink-soft">{{ m.reason }}</div>
              <div class="tabular text-xs text-ink-faint">
                {{ clockTime(m.createdAt) }} · {{ m.createdByName }}<template v-if="m.approvedByName"> · disetujui {{ m.approvedByName }}</template>
              </div>
            </div>
            <span :class="['tabular whitespace-nowrap font-semibold', m.amount < 0 ? 'text-alert-600' : 'text-ink']">{{ signedRupiah(m.amount) }}</span>
          </li>
          <li v-if="!movements.length" class="p-3 text-ink-soft">Belum ada mutasi.</li>
        </ul>

        <h3 class="mt-6 text-sm font-semibold text-ink-soft">Hitungan kas</h3>
        <ol class="mt-2 space-y-3">
          <li v-for="c in detail.counts" :key="c.id" class="rounded-lg border border-line p-3">
            <div class="flex items-baseline justify-between gap-2">
              <span class="font-semibold">{{ COUNT_TYPE_LABEL[c.countType] ?? c.countType }}</span>
              <span class="tabular text-xs text-ink-soft">{{ formatDateTime(c.countedAt) }} · {{ c.countedByUsername }}</span>
            </div>
            <div class="mt-2 grid grid-cols-3 gap-2 text-sm">
              <div><div class="text-xs text-ink-soft">Dihitung</div><div class="tabular font-semibold">{{ formatRupiah(c.totalAmount) }}</div></div>
              <div><div class="text-xs text-ink-soft">Seharusnya</div><div class="tabular">{{ formatRupiah(c.expectedAmount) }}</div></div>
              <div><div class="text-xs text-ink-soft">Selisih</div><div :class="['tabular', diffClass(c.difference)]">{{ signed(c.difference) }}</div></div>
            </div>
            <details class="mt-2 text-sm">
              <summary class="cursor-pointer text-xs font-medium text-jade-700">Rincian pecahan</summary>
              <table class="mt-2 w-full text-xs">
                <tbody>
                  <tr v-for="i in c.items.filter((x) => x.quantity > 0)" :key="`${i.kind}-${i.value}`" class="border-t border-line">
                    <td class="tabular py-1">{{ formatNumber(Number(i.value)) }} <span class="text-ink-faint">{{ i.kind === 'COIN' ? 'koin' : '' }}</span></td>
                    <td class="tabular py-1 text-right">× {{ i.quantity }}</td>
                    <td class="tabular py-1 text-right font-semibold">{{ formatRupiah(i.subtotal) }}</td>
                  </tr>
                </tbody>
              </table>
            </details>
            <p v-if="c.note" class="mt-2 text-xs text-ink-soft">{{ c.note }}</p>
          </li>
        </ol>
        <p v-if="lastCount(detail) === null" class="text-sm text-ink-soft">Belum ada hitungan.</p>
      </template>
    </Drawer>

    <ShiftReportDialog v-model:visible="reportOpen" :session-id="detail?.id ?? null" :type="reportType" />

    <Dialog v-model:visible="adjustOpen" header="Penyesuaian kas" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="submitAdjust">
        <p class="text-sm text-ink-soft">
          Koreksi catatan laci {{ detail?.employeeName }} (mis. salah catat). Tercatat atas nama Anda dan masuk audit log.
        </p>
        <SelectButton v-model="adjustDir" :options="[{ v: 1, l: 'Tambah' }, { v: -1, l: 'Kurangi' }]" option-label="l"
          option-value="v" :allow-empty="false" aria-label="Arah penyesuaian" />
        <div>
          <label for="adj-amount" class="mb-1 block text-sm font-medium">Nominal</label>
          <InputNumber v-model="adjustAmount" input-id="adj-amount" mode="currency" currency="IDR" locale="id-ID"
            :min-fraction-digits="0" :max-fraction-digits="0" :min="0" class="w-full" input-class="w-full tabular" />
        </div>
        <div>
          <label for="adj-reason" class="mb-1 block text-sm font-medium">Alasan</label>
          <Textarea id="adj-reason" v-model="adjustReason" rows="2" maxlength="500" class="w-full" />
          <p class="mt-1 text-xs text-ink-faint">Minimal 5 karakter.</p>
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="adjustOpen = false" />
          <Button label="Simpan penyesuaian" type="submit" :loading="busy"
            :disabled="!adjustAmount || adjustReason.trim().length < 5" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
