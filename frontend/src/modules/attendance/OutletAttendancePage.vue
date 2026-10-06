<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import Textarea from 'primevue/textarea'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Attendance } from '@/types/api'
import { STATUS_CLASS, STATUS_LABEL, breakLabel, clockTime, workedLabel } from './attendanceFormat'

const session = useSessionStore()
const { busy, run } = useApiAction()

const outlets = computed(() => session.outlets.filter((o) => session.can('attendance.view', o.id)))
const outletId = ref<string | null>(outlets.value.find((o) => o.id === session.outletId)?.id ?? outlets.value[0]?.id ?? null)
const date = ref<Date | null>(null)
const rows = ref<Attendance[]>([])
const loading = ref(false)
const now = ref(new Date())

const canForce = computed(() => !!outletId.value && session.can('attendance.force_clock_out', outletId.value))
const openCount = computed(() => rows.value.filter((r) => r.status === 'WORKING' || r.status === 'ON_BREAK').length)

function ymd(d: Date) {
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

async function load() {
  if (!outletId.value) return
  loading.value = true
  now.value = new Date()
  await run(async () => {
    rows.value = (await api().get<Attendance[]>('/api/attendance', {
      query: { outletId: outletId.value, businessDate: date.value ? ymd(date.value) : undefined },
    })).data
  })
  loading.value = false
}
watch([outletId, date], load)
onMounted(load)

// ---------------------------------------------------------------- force clock out
const target = ref<Attendance | null>(null)
const reason = ref('')
const reasonError = ref<string | null>(null)
const isSelf = (a: Attendance) => a.employeeId === session.me?.employee?.id

function openForce(a: Attendance) {
  target.value = a
  reason.value = ''
  reasonError.value = null
}

async function submitForce() {
  if (!target.value) return
  if (reason.value.trim().length < 5) {
    reasonError.value = 'Alasan minimal 5 karakter'
    return
  }
  const ok = await run(
    (key) => api().post(`/api/attendance/${target.value!.id}/force-clock-out`, { reason: reason.value.trim() }, { idempotencyKey: key }),
    'Kehadiran ditutup',
  )
  if (ok) {
    target.value = null
    await load()
  }
}
</script>

<template>
  <div>
    <PageHeader title="Kehadiran outlet" description="Siapa yang sedang bekerja atau istirahat pada business date ini.">
      <template #actions>
        <Select v-model="outletId" :options="outlets" option-label="name" option-value="id" class="min-w-52" aria-label="Outlet" />
        <DatePicker v-model="date" date-format="dd/mm/yy" placeholder="Business date hari ini" show-icon show-button-bar aria-label="Business date" />
        <Button icon="pi pi-refresh" severity="secondary" text aria-label="Muat ulang" @click="load" />
      </template>
    </PageHeader>

    <p class="mb-3 text-sm text-ink-soft">
      <span class="tabular font-semibold text-ink">{{ openCount }}</span> orang masih bekerja/istirahat,
      <span class="tabular font-semibold text-ink">{{ rows.length }}</span> kehadiran tercatat.
    </p>

    <DataTable :value="rows" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface">
      <template #empty>Belum ada yang clock in pada business date ini.</template>
      <Column header="Karyawan">
        <template #body="{ data }">
          <div class="font-semibold">{{ data.employeeName }}</div>
          <div class="tabular text-xs text-ink-soft">{{ data.employeeCode }}</div>
        </template>
      </Column>
      <Column header="Masuk"><template #body="{ data }"><span class="tabular">{{ clockTime(data.clockIn) }}</span></template></Column>
      <Column header="Pulang"><template #body="{ data }"><span class="tabular">{{ clockTime(data.clockOut) }}</span></template></Column>
      <Column header="Istirahat"><template #body="{ data }"><span class="tabular text-sm">{{ breakLabel(data, now) }}</span></template></Column>
      <Column header="Jam kerja"><template #body="{ data }"><span class="tabular font-semibold">{{ workedLabel(data, now) }}</span></template></Column>
      <Column header="Status">
        <template #body="{ data }">
          <span :class="['rounded-full px-2 py-0.5 text-xs font-medium', STATUS_CLASS[data.status as keyof typeof STATUS_CLASS]]">
            {{ STATUS_LABEL[data.status as keyof typeof STATUS_LABEL] }}
          </span>
          <div v-if="data.forcedReason" class="mt-1 max-w-[14rem] text-xs text-ink-soft">{{ data.forcedReason }} ({{ data.clockOutByUsername }})</div>
        </template>
      </Column>
      <Column class="w-40">
        <template #body="{ data }">
          <Button
            v-if="canForce && !isSelf(data) && (data.status === 'WORKING' || data.status === 'ON_BREAK')"
            label="Tutup paksa"
            size="small"
            severity="danger"
            text
            @click="openForce(data)"
          />
        </template>
      </Column>
    </DataTable>

    <Dialog :visible="!!target" :header="`Tutup paksa kehadiran ${target?.employeeName ?? ''}`" modal class="w-full max-w-md" @update:visible="(v) => { if (!v) target = null }">
      <form class="space-y-4" @submit.prevent="submitForce">
        <p class="text-sm text-ink-soft">
          Dipakai bila karyawan lupa clock out. Jam pulang dicatat sekarang, istirahat yang masih berjalan ditutup,
          dan tindakan ini tercatat atas nama Anda di audit log. Jika karyawan masih memegang kasir, terminalnya
          otomatis dikunci.
        </p>
        <div>
          <label for="force-reason" class="mb-1 block text-sm font-medium">Alasan <span class="text-alert-600">*</span></label>
          <Textarea id="force-reason" v-model="reason" rows="3" class="w-full" maxlength="500" />
          <small v-if="reasonError" class="text-alert-600" role="alert">{{ reasonError }}</small>
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="target = null" />
          <Button label="Tutup kehadiran" severity="danger" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </div>
</template>
