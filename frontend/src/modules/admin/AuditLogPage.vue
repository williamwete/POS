<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import DataTable, { type DataTablePageEvent } from 'primevue/datatable'
import Column from 'primevue/column'
import Select from 'primevue/select'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import Message from 'primevue/message'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { AuditLog, PageResult } from '@/types/api'
import { formatDateTime } from '@/utils/format'

const session = useSessionStore()
const { run } = useApiAction()

const orgWide = computed(() => session.can('audit.view', 'org'))
const viewableOutlets = computed(() => session.outlets.filter((o) => session.can('audit.view', o.id)))
const outletOptions = computed(() => [
  ...(orgWide.value ? [{ name: 'Semua outlet', id: null as string | null }] : []),
  ...viewableOutlets.value.map((o) => ({ name: `${o.code} ${o.name}`, id: o.id as string | null })),
])

const filter = reactive({
  outletId: (orgWide.value ? null : viewableOutlets.value[0]?.id ?? null) as string | null,
  entityType: null as string | null,
  action: '',
  range: null as Date[] | null,
})
const page = ref(0)
const size = 50
const result = ref<PageResult<AuditLog>>({ items: [], page: 0, size, total: 0 })
const loading = ref(false)
const expanded = ref<Record<string, boolean>>({})

const ENTITY_TYPES = ['USER', 'EMPLOYEE', 'OUTLET', 'WAREHOUSE', 'TERMINAL', 'DEVICE', 'ROLE'].map((v) => ({ label: v, value: v }))

function dayStart(d: Date) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x }

async function load() {
  loading.value = true
  const [from, to] = filter.range ?? []
  await run(async () => {
    result.value = (await api().get<PageResult<AuditLog>>('/api/audit-logs', {
      query: {
        outletId: filter.outletId,
        entityType: filter.entityType,
        action: filter.action.trim().toUpperCase() || undefined,
        from: from ? dayStart(from).toISOString() : undefined,
        to: to ? new Date(dayStart(to).getTime() + 86_400_000).toISOString() : undefined,
        page: page.value,
        size,
      },
    })).data
  })
  loading.value = false
}

watch(() => [filter.outletId, filter.entityType, filter.range], () => { page.value = 0; void load() })
let t: number | undefined
watch(() => filter.action, () => { window.clearTimeout(t); t = window.setTimeout(() => { page.value = 0; void load() }, 400) })
onMounted(load)

function onPage(e: DataTablePageEvent) {
  page.value = e.page
  void load()
}

function pretty(v: unknown) {
  return v === null || v === undefined ? '—' : JSON.stringify(v, null, 2)
}
</script>

<template>
  <div>
    <PageHeader
      title="Audit log"
      description="Jejak setiap perubahan penting: siapa, kapan, dari device mana, dan nilai sebelum/sesudah. Catatan tidak dapat diubah atau dihapus."
    />

    <Message v-if="!outletOptions.length" severity="secondary" :closable="false">Anda tidak memiliki akses audit di outlet mana pun.</Message>

    <template v-else>
      <div class="mb-4 flex flex-wrap gap-3">
        <Select v-model="filter.outletId" :options="outletOptions" option-label="name" option-value="id" placeholder="Semua outlet" class="min-w-52" aria-label="Outlet" />
        <Select v-model="filter.entityType" :options="ENTITY_TYPES" option-label="label" option-value="value" placeholder="Semua entitas" show-clear class="min-w-44" aria-label="Entitas" />
        <InputText v-model="filter.action" placeholder="Aksi, mis. USER_CREATED" class="min-w-56" aria-label="Aksi" />
        <DatePicker v-model="filter.range" selection-mode="range" date-format="dd/mm/yy" placeholder="Rentang tanggal" show-icon show-button-bar class="min-w-56" aria-label="Rentang tanggal" />
      </div>

      <DataTable
        v-model:expanded-rows="expanded"
        :value="result.items" :loading="loading" data-key="id" lazy paginator
        :rows="size" :total-records="result.total" :first="page * size"
        class="rounded-2xl border border-line bg-surface" @page="onPage"
      >
        <template #empty>Tidak ada catatan untuk filter ini.</template>
        <Column expander class="w-12" />
        <Column header="Waktu"><template #body="{ data }"><span class="tabular text-sm">{{ formatDateTime(data.createdAt) }}</span></template></Column>
        <Column header="Aksi"><template #body="{ data }"><span class="tabular text-sm font-semibold">{{ data.action }}</span></template></Column>
        <Column header="Pelaku"><template #body="{ data }">{{ data.actorType === 'SYSTEM' ? 'Sistem' : data.actorUsername ?? data.actorUserId }}</template></Column>
        <Column header="Entitas"><template #body="{ data }"><span class="text-sm">{{ data.entityType }}</span></template></Column>
        <Column header="Alasan"><template #body="{ data }"><span class="text-sm text-ink-soft">{{ data.reason ?? '—' }}</span></template></Column>
        <template #expansion="{ data }">
          <div class="grid gap-4 p-2 lg:grid-cols-2">
            <div>
              <p class="mb-1 text-xs font-semibold text-ink-soft">Sebelum</p>
              <pre class="max-h-72 overflow-auto rounded-md bg-field p-3 text-xs">{{ pretty(data.oldValue) }}</pre>
            </div>
            <div>
              <p class="mb-1 text-xs font-semibold text-ink-soft">Sesudah</p>
              <pre class="max-h-72 overflow-auto rounded-md bg-field p-3 text-xs">{{ pretty(data.newValue) }}</pre>
            </div>
            <dl class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-1 text-xs text-ink-soft lg:col-span-2">
              <dt>ID entitas</dt><dd class="tabular">{{ data.entityId ?? '—' }}</dd>
              <dt>Device</dt><dd class="tabular">{{ data.deviceId ?? '—' }}</dd>
              <dt>Alamat IP</dt><dd class="tabular">{{ data.ipAddress ?? '—' }}</dd>
              <dt>Kode request</dt><dd class="tabular">{{ data.requestId ?? '—' }}</dd>
              <dt>Urutan</dt><dd class="tabular">#{{ data.seq }}</dd>
            </dl>
          </div>
        </template>
      </DataTable>
    </template>
  </div>
</template>
