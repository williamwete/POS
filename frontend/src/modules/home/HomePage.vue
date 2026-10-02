<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useSessionStore } from '@/stores/session'
import { api } from '@/services'
import type { Permission } from '@/types/api'
import { formatBusinessDate } from '@/utils/format'
import AttendanceCard from '@/modules/attendance/AttendanceCard.vue'

const session = useSessionStore()
const now = ref(new Date())
const catalog = ref<Permission[]>([])
let timer: number | undefined

const clock = computed(() =>
  new Intl.DateTimeFormat('id-ID', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    timeZone: session.currentOutlet?.timezone ?? 'Asia/Jakarta',
  }).format(now.value),
)

const MODULE_LABELS: Record<string, string> = {
  attendance: 'Kehadiran', cashier: 'Kasir', sale: 'Penjualan', cash: 'Kas', stock: 'Stok',
  report: 'Laporan', user: 'User', employee: 'Karyawan', outlet: 'Outlet', terminal: 'Terminal',
  role: 'Role', configuration: 'Konfigurasi', audit: 'Audit', sync: 'Sinkronisasi',
}

const grouped = computed(() => {
  const mine = new Set([...(session.currentOutlet?.permissions ?? []), ...(session.me?.organizationPermissions ?? [])])
  const groups = new Map<string, Permission[]>()
  for (const p of catalog.value) {
    if (!mine.has(p.code)) continue
    const list = groups.get(p.module) ?? []
    list.push(p)
    groups.set(p.module, list)
  }
  return [...groups.entries()].map(([module, perms]) => ({ module, label: MODULE_LABELS[module] ?? module, perms }))
})

onMounted(async () => {
  timer = window.setInterval(() => (now.value = new Date()), 1000)
  try {
    catalog.value = (await api().get<Permission[]>('/api/permissions')).data
  } catch {
    catalog.value = []
  }
})
onBeforeUnmount(() => window.clearInterval(timer))
</script>

<template>
  <div class="mx-auto max-w-5xl">
    <div class="flex flex-wrap items-end justify-between gap-4">
      <div>
        <p class="text-sm text-ink-soft">Selamat bekerja,</p>
        <h1 class="text-3xl font-bold">{{ session.me?.employee?.fullName ?? session.me?.user.displayName }}</h1>
      </div>
      <div class="text-right">
        <div class="tabular text-4xl font-bold tracking-tight text-jade-700" aria-live="off">{{ clock }}</div>
        <div class="text-sm text-ink-soft">{{ session.currentOutlet?.timezone }}</div>
      </div>
    </div>

    <dl class="mt-8 grid gap-px overflow-hidden rounded-lg border border-line bg-line sm:grid-cols-2 lg:grid-cols-4">
      <div class="bg-surface p-4">
        <dt class="text-xs text-ink-soft">Karyawan</dt>
        <dd class="mt-1 font-semibold">
          <span class="tabular">{{ session.me?.employee?.employeeCode ?? '—' }}</span>
          <span class="block text-sm font-normal text-ink-soft">{{ session.me?.employee?.position ?? 'Tanpa data karyawan' }}</span>
        </dd>
      </div>
      <div class="bg-surface p-4">
        <dt class="text-xs text-ink-soft">Outlet</dt>
        <dd class="mt-1 font-semibold">{{ session.currentOutlet?.name }}</dd>
      </div>
      <div class="bg-surface p-4">
        <dt class="text-xs text-ink-soft">Terminal</dt>
        <dd class="tabular mt-1 font-semibold">{{ session.terminal?.code }} <span class="font-normal text-ink-soft">{{ session.terminal?.name }}</span></dd>
      </div>
      <div class="bg-amber-100 p-4">
        <dt class="text-xs text-amber-700">Business date</dt>
        <dd class="mt-1 font-semibold">{{ formatBusinessDate(session.currentOutlet?.businessDate) }}</dd>
      </div>
    </dl>

    <AttendanceCard class="mt-6" />

    <section class="mt-10">
      <h2 class="text-lg font-semibold">Yang dapat Anda lakukan di outlet ini</h2>
      <p class="text-sm text-ink-soft">Ditentukan oleh role Anda: {{ session.roleSummary.join(', ') || 'belum ada role' }}.</p>
      <p v-if="grouped.length === 0" class="mt-4 rounded-lg border border-dashed border-line p-4 text-sm text-ink-soft">
        Akun Anda belum memiliki izin di outlet ini. Hubungi supervisor atau admin.
      </p>
      <div v-else class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div v-for="g in grouped" :key="g.module" class="rounded-lg border border-line bg-surface p-4">
          <h3 class="font-semibold">{{ g.label }}</h3>
          <ul class="mt-2 space-y-1 text-sm text-ink-soft">
            <li v-for="p in g.perms" :key="p.code" class="flex gap-2"><i class="pi pi-check mt-1 text-xs text-jade-600" />{{ p.description }}</li>
          </ul>
        </div>
      </div>
    </section>
  </div>
</template>
