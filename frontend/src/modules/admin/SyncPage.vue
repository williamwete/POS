<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import Drawer from 'primevue/drawer'
import Message from 'primevue/message'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { SyncJob, SyncJobStatus, SyncJobType, SyncLog, SyncRunResult, SyncStatus } from '@/types/api'
import { formatDateTime } from '@/utils/format'

/**
 * Dashboard sinkronisasi Openbravo (§42): antrean dokumen keluar, sinkron master data, dan daftar yang
 * perlu perhatian (gagal / manual review) dengan tombol coba lagi. Kredensial Openbravo tidak pernah ada di sini.
 */
const session = useSessionStore()
const { busy, run } = useApiAction()
const canManage = computed(() => session.can('sync.manage', 'org'))

const status = ref<SyncStatus | null>(null)
const problems = ref<SyncJob[]>([])
const loading = ref(false)

async function load() {
  loading.value = true
  await run(async () => {
    const [s, e] = await Promise.all([
      api().get<SyncStatus>('/api/sync/status'),
      api().get<SyncJob[]>('/api/sync/errors'),
    ])
    status.value = s.data
    problems.value = e.data
  })
  loading.value = false
}
let timer: number | undefined
onMounted(() => {
  void load()
  timer = window.setInterval(() => { if (!busy.value) void load() }, 30_000)
})
onBeforeUnmount(() => window.clearInterval(timer))

const DOC_TYPES: { type: SyncJobType; label: string; icon: string }[] = [
  { type: 'SALE', label: 'Penjualan', icon: 'pi pi-receipt' },
  { type: 'RETURN', label: 'Retur', icon: 'pi pi-replay' },
  { type: 'CASHUP', label: 'Cash-up (Z)', icon: 'pi pi-wallet' },
]
const MASTER: { type: SyncJobType; label: string }[] = [
  { type: 'MASTER_PRODUCT', label: 'Produk' },
  { type: 'MASTER_PRICE', label: 'Harga' },
  { type: 'MASTER_STOCK', label: 'Stok' },
  { type: 'MASTER_CUSTOMER', label: 'Customer' },
]
const TYPE_LABEL: Record<string, string> = Object.fromEntries([...DOC_TYPES, ...MASTER].map((x) => [x.type, x.label]))
const STATUS: Record<SyncJobStatus, { label: string; cls: string }> = {
  PENDING: { label: 'Antre', cls: 'bg-field text-ink-soft' },
  PROCESSING: { label: 'Diproses', cls: 'bg-jade-50 text-jade-700' },
  SUCCESS: { label: 'Terkirim', cls: 'bg-jade-50 text-jade-700' },
  FAILED: { label: 'Gagal, dicoba lagi', cls: 'bg-amber-100 text-amber-700' },
  RETRYING: { label: 'Dicoba ulang', cls: 'bg-amber-100 text-amber-700' },
  MANUAL_REVIEW: { label: 'Perlu ditinjau', cls: 'bg-alert-50 text-alert-600' },
}
const MODE: Record<string, { label: string; cls: string }> = {
  HTTP: { label: 'Terhubung ke Openbravo', cls: 'bg-jade-50 text-jade-700' },
  SIMULATOR: { label: 'Simulator (pengembangan)', cls: 'bg-amber-100 text-amber-700' },
  DISABLED: { label: 'Belum dikonfigurasi', cls: 'bg-alert-50 text-alert-600' },
}

function count(type: SyncJobType, statuses: SyncJobStatus[]) {
  return (status.value?.counts ?? []).filter((c) => c.jobType === type && statuses.includes(c.status))
    .reduce((n, c) => n + Number(c.count), 0)
}
const lastMaster = (type: SyncJobType) => status.value?.lastMasterSyncs.find((j) => j.jobType === type) ?? null

const lastRun = ref<SyncRunResult['summary'] | null>(null)
async function runNow(types: SyncJobType[] = []) {
  const res = await run(async () => (await api().post<SyncRunResult>('/api/sync/run', { types })).data,
    types.length ? 'Sinkron master selesai' : 'Antrean diproses')
  if (res) {
    lastRun.value = res.summary
    await load()
  }
}

async function retry(job: SyncJob) {
  const res = await run(async () => (await api().post<SyncJob>(`/api/sync/${job.id}/retry`, {})).data, 'Dijadwalkan ulang')
  if (res) await load()
}

const detail = ref<{ job: SyncJob; logs: SyncLog[] } | null>(null)
async function openDetail(job: SyncJob) {
  const res = await run(async () => (await api().get<{ job: SyncJob; logs: SyncLog[] }>(`/api/sync/jobs/${job.id}`)).data)
  if (res) detail.value = res
}

const waiting = (j: SyncJob) => j.status === 'PENDING' && (j.lastError ?? '').startsWith('WAITING')
</script>

<template>
  <div>
    <PageHeader title="Sinkronisasi Openbravo"
      description="Transaksi tetap tersimpan di POS walau Openbravo tidak tersedia; antrean dikirim otomatis dan dicoba ulang bertahap.">
      <template #actions>
        <span v-if="status" :class="['rounded-full px-3 py-1 text-xs font-medium', MODE[status.mode]!.cls]">{{ MODE[status.mode]!.label }}</span>
        <Button v-if="canManage" label="Proses antrean sekarang" icon="pi pi-play" :loading="busy" :disabled="!status?.enabled" @click="runNow()" />
        <Button icon="pi pi-refresh" severity="secondary" text aria-label="Muat ulang" :loading="loading" @click="load" />
      </template>
    </PageHeader>

    <Message v-if="status && !status.enabled" severity="warn" :closable="false" class="mb-4">
      Integrasi Openbravo belum dikonfigurasi di server (POS_OPENBRAVO_MODE). Dokumen tetap mengantre dan akan terkirim
      setelah diaktifkan.
    </Message>
    <p v-if="lastRun" class="mb-4 text-sm text-ink-soft">
      Terakhir dijalankan: <span class="tabular">{{ lastRun.processed }}</span> diproses,
      <span class="tabular text-jade-700">{{ lastRun.success }}</span> terkirim,
      <span class="tabular text-alert-600">{{ lastRun.failed }}</span> gagal,
      <span class="tabular">{{ lastRun.deferred }}</span> menunggu dokumen lain<template v-if="lastRun.busy"> (worker sedang berjalan)</template>.
    </p>

    <!-- dokumen keluar -->
    <section class="grid gap-3 md:grid-cols-3" aria-label="Dokumen ke Openbravo">
      <div v-for="d in DOC_TYPES" :key="d.type" class="rounded-2xl border border-line bg-surface p-4">
        <div class="flex items-center gap-2 font-semibold"><i :class="d.icon" aria-hidden="true" /> {{ d.label }}</div>
        <dl class="mt-3 grid grid-cols-4 gap-2 text-center">
          <div><dt class="text-[11px] text-ink-soft">Antre</dt><dd class="tabular text-lg font-bold">{{ count(d.type, ['PENDING', 'PROCESSING', 'RETRYING']) }}</dd></div>
          <div><dt class="text-[11px] text-ink-soft">Gagal</dt><dd class="tabular text-lg font-bold text-amber-700">{{ count(d.type, ['FAILED']) }}</dd></div>
          <div><dt class="text-[11px] text-ink-soft">Ditinjau</dt><dd class="tabular text-lg font-bold text-alert-600">{{ count(d.type, ['MANUAL_REVIEW']) }}</dd></div>
          <div><dt class="text-[11px] text-ink-soft">Terkirim 24j</dt><dd class="tabular text-lg font-bold text-jade-700">{{ count(d.type, ['SUCCESS']) }}</dd></div>
        </dl>
      </div>
    </section>
    <p v-if="status?.oldestPendingAt" class="mt-2 text-xs text-ink-soft">
      Dokumen tertua yang belum terkirim: {{ formatDateTime(status.oldestPendingAt) }}
    </p>

    <!-- master data -->
    <section class="mt-6 rounded-2xl border border-line bg-surface p-5" aria-labelledby="master-h">
      <h2 id="master-h" class="font-semibold">Master data dari Openbravo</h2>
      <ul class="mt-3 divide-y divide-line">
        <li v-for="m in MASTER" :key="m.type" class="flex flex-wrap items-center justify-between gap-3 py-3">
          <div>
            <div class="font-medium">{{ m.label }}</div>
            <div class="text-xs text-ink-soft">
              <template v-if="lastMaster(m.type)">
                {{ STATUS[lastMaster(m.type)!.status].label }} · {{ formatDateTime(lastMaster(m.type)!.syncFinishedAt ?? lastMaster(m.type)!.createdAt) }}
                · <span class="tabular">{{ lastMaster(m.type)!.recordsSuccess }}/{{ lastMaster(m.type)!.recordsProcessed }}</span> berhasil
                <template v-if="lastMaster(m.type)!.recordsFailed"> · <span class="text-alert-600">{{ lastMaster(m.type)!.recordsFailed }} gagal</span></template>
              </template>
              <template v-else>Belum pernah disinkronkan</template>
            </div>
          </div>
          <Button v-if="canManage" :label="`Sinkron ${m.label.toLowerCase()}`" icon="pi pi-download" size="small" severity="secondary"
            :loading="busy" :disabled="!status?.enabled" @click="runNow([m.type])" />
        </li>
      </ul>
    </section>

    <!-- perlu perhatian -->
    <section class="mt-6 rounded-2xl border border-line bg-surface p-5" aria-labelledby="problem-h">
      <h2 id="problem-h" class="font-semibold">Perlu perhatian <span class="tabular text-ink-soft">({{ problems.length }})</span></h2>
      <div class="mt-3 overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-xs text-ink-soft">
            <tr>
              <th class="py-2 font-medium">Dokumen</th>
              <th class="py-2 font-medium">Status</th>
              <th class="py-2 font-medium">Percobaan</th>
              <th class="py-2 font-medium">Penyebab</th>
              <th class="py-2" />
            </tr>
          </thead>
          <tbody>
            <tr v-for="j in problems" :key="j.id" class="border-t border-line align-top">
              <td class="py-2">
                <div class="font-medium">{{ TYPE_LABEL[j.jobType] }}</div>
                <div class="tabular text-xs text-ink-soft">{{ j.entityRef ?? '—' }}<template v-if="j.outletCode"> · {{ j.outletCode }}</template></div>
              </td>
              <td class="py-2">
                <span :class="['whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium',
                               waiting(j) ? 'bg-field text-ink-soft' : STATUS[j.status].cls]">
                  {{ waiting(j) ? 'Menunggu dokumen lain' : STATUS[j.status].label }}
                </span>
                <div v-if="j.status === 'FAILED'" class="mt-1 text-xs text-ink-soft">berikutnya {{ formatDateTime(j.nextAttemptAt) }}</div>
              </td>
              <td class="tabular py-2">{{ j.attempts }}/{{ j.maxAttempts }}</td>
              <td class="max-w-md py-2 text-xs text-ink-soft"><span class="line-clamp-2">{{ j.lastError }}</span></td>
              <td class="whitespace-nowrap py-2 text-right">
                <Button icon="pi pi-list" text size="small" aria-label="Riwayat" @click="openDetail(j)" />
                <Button v-if="canManage && (j.status === 'FAILED' || j.status === 'MANUAL_REVIEW')" label="Coba lagi" size="small"
                  :loading="busy" @click="retry(j)" />
              </td>
            </tr>
            <tr v-if="!problems.length"><td colspan="5" class="py-4 text-ink-soft">Tidak ada dokumen yang bermasalah.</td></tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-xs text-ink-faint">
        Retry otomatis: 30 detik, 1 menit, 5 menit, 15 menit; setelah itu "Perlu ditinjau". Pemetaan ID yang belum diisi
        langsung ditinjau — lengkapi di <RouterLink :to="{ name: 'openbravo-mappings' }" class="underline">Pemetaan Openbravo</RouterLink>, lalu Coba lagi.
      </p>
    </section>

    <Drawer :visible="!!detail" position="right" :header="detail ? `${TYPE_LABEL[detail.job.jobType]} ${detail.job.entityRef ?? ''}` : ''"
      :style="{ width: 'min(100vw, 30rem)' }" @update:visible="(v) => { if (!v) detail = null }">
      <template v-if="detail">
        <dl class="grid grid-cols-2 gap-3 text-sm">
          <div><dt class="text-xs text-ink-soft">Status</dt><dd class="font-semibold">{{ STATUS[detail.job.status].label }}</dd></div>
          <div><dt class="text-xs text-ink-soft">Dokumen Openbravo</dt><dd class="tabular font-semibold">{{ detail.job.openbravoDocumentNo ?? '—' }}</dd></div>
          <div><dt class="text-xs text-ink-soft">Dibuat</dt><dd class="tabular">{{ formatDateTime(detail.job.createdAt) }}</dd></div>
          <div><dt class="text-xs text-ink-soft">Percobaan</dt><dd class="tabular">{{ detail.job.attempts }}/{{ detail.job.maxAttempts }}</dd></div>
        </dl>
        <h3 class="mt-6 text-sm font-semibold text-ink-soft">Riwayat</h3>
        <ol class="mt-2 space-y-2">
          <li v-for="(l, i) in detail.logs" :key="i" class="rounded-lg border border-line p-3 text-sm">
            <div class="flex justify-between gap-2">
              <span class="font-medium">#{{ l.attempt }} · {{ l.status }}</span>
              <span class="tabular text-xs text-ink-soft">{{ formatDateTime(l.createdAt) }}</span>
            </div>
            <p v-if="l.message" class="mt-1 break-words text-xs text-ink-soft">{{ l.message }}</p>
          </li>
          <li v-if="!detail.logs.length" class="text-sm text-ink-soft">Belum ada percobaan.</li>
        </ol>
      </template>
    </Drawer>
  </div>
</template>
