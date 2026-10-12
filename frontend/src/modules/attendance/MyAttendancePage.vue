<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import DatePicker from 'primevue/datepicker'
import PageHeader from '@/components/PageHeader.vue'
import AttendanceCard from './AttendanceCard.vue'
import { useAttendanceStore } from '@/stores/attendance'
import { useCashierStore } from '@/stores/cashier'
import { useRouter } from 'vue-router'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { Attendance } from '@/types/api'
import { formatBusinessDate } from '@/utils/format'
import { STATUS_CLASS, STATUS_LABEL, breakLabel, clockTime, workedLabel } from './attendanceFormat'

const { run } = useApiAction()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const router = useRouter()

// Alur Figma: setelah Clock in → Beginning cash balance (bila kasir belum dibuka) → katalog.
watch(() => attendance.isWorking, (working, was) => {
  if (working && !was) void router.push({ name: cashier.current ? 'pos' : 'cashier-open' })
  else if (!working && was) void load()
})
const rows = ref<Attendance[]>([])
const loading = ref(false)
const now = new Date()
const range = ref<Date[] | null>([new Date(now.getTime() - 30 * 86_400_000), now])

function ymd(d: Date) {
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

async function load() {
  const [from, to] = range.value ?? []
  loading.value = true
  await run(async () => {
    rows.value = (await api().get<Attendance[]>('/api/attendance/history', {
      query: { from: from ? ymd(from) : undefined, to: to ? ymd(to) : undefined },
    })).data
  })
  loading.value = false
}
watch(range, (r) => { if (!r || r[1]) void load() })
onMounted(load)
</script>

<template>
  <div>
    <PageHeader title="Clock in/Clock out" description="Jam dicatat oleh server, bukan perangkat.">
      <template #actions>
        <DatePicker v-model="range" selection-mode="range" date-format="dd/mm/yy" show-icon aria-label="Rentang tanggal" />
      </template>
    </PageHeader>

    <AttendanceCard class="mb-6" />

    <h2 class="mb-2 text-lg font-semibold">Riwayat</h2>
    <DataTable :value="rows" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface" paginator :rows="31">
      <template #empty>Belum ada kehadiran pada rentang ini.</template>
      <Column header="Business date"><template #body="{ data }"><span class="text-sm">{{ formatBusinessDate(data.businessDate) }}</span></template></Column>
      <Column header="Outlet"><template #body="{ data }"><span class="tabular">{{ data.outletCode }}</span></template></Column>
      <Column header="Masuk"><template #body="{ data }"><span class="tabular">{{ clockTime(data.clockIn) }}</span></template></Column>
      <Column header="Pulang"><template #body="{ data }"><span class="tabular">{{ clockTime(data.clockOut) }}</span></template></Column>
      <Column header="Istirahat"><template #body="{ data }"><span class="tabular text-sm">{{ breakLabel(data, new Date()) }}</span></template></Column>
      <Column header="Jam kerja"><template #body="{ data }"><span class="tabular font-semibold">{{ workedLabel(data, new Date()) }}</span></template></Column>
      <Column header="Status">
        <template #body="{ data }">
          <span :class="['rounded-full px-2 py-0.5 text-xs font-medium', STATUS_CLASS[data.status as keyof typeof STATUS_CLASS]]">
            {{ STATUS_LABEL[data.status as keyof typeof STATUS_LABEL] }}
          </span>
        </template>
      </Column>
    </DataTable>
  </div>
</template>
