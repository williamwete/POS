<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Button from 'primevue/button'
import Drawer from 'primevue/drawer'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { CashCount, CashierSession } from '@/types/api'
import { formatDateTime } from '@/utils/format'
import { formatNumber, formatRupiah } from '@/utils/money'
import { clockTime } from '@/modules/attendance/attendanceFormat'
import { COUNT_TYPE_LABEL, LOCK_REASON_LABEL, SESSION_STATUS_CLASS, SESSION_STATUS_LABEL } from './cashierFormat'

const session = useSessionStore()
const { run } = useApiAction()

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

async function openDetail(row: CashierSession) {
  await run(async () => {
    detail.value = (await api().get<CashierSession>(`/api/cashier/sessions/${row.id}`)).data
  })
}

function lastCount(s: CashierSession): CashCount | null {
  return s.counts.length ? s.counts[s.counts.length - 1]! : null
}

function diffClass(n?: number | null) {
  if (n === null || n === undefined) return 'text-ink-faint'
  const v = Number(n)
  return v === 0 ? 'text-jade-700' : 'text-alert-600 font-semibold'
}

function signed(n?: number | null) {
  if (n === null || n === undefined) return '—'
  const v = Number(n)
  return (v > 0 ? '+' : '') + formatRupiah(v)
}
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
      class="rounded-lg border border-line bg-surface"
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
  </div>
</template>
