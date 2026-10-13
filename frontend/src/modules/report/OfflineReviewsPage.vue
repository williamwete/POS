<script setup lang="ts">
import { onMounted, ref } from 'vue'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import { useApiAction } from '@/composables/useApiAction'
import type { OfflineReview } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/** Transaksi tunai offline yang berbeda dari data server atau melanggar batas: ditinjau lalu ditutup dengan catatan. */
const session = useSessionStore()
const { run, busy } = useApiAction()
const status = ref<'OPEN' | 'RESOLVED'>('OPEN')
const rows = ref<OfflineReview[]>([])
const loading = ref(true)
const notes = ref<Record<string, string>>({})

async function load() {
  if (!session.outletId) return
  loading.value = true
  const res = await run(async () => (await api().get<OfflineReview[]>('/api/offline-reviews', {
    query: { outletId: session.outletId, status: status.value },
  })).data)
  if (res) rows.value = res.map((r) => ({ ...r, clientTotal: Number(r.clientTotal), serverTotal: Number(r.serverTotal) }))
  loading.value = false
}
onMounted(load)
function show(s: 'OPEN' | 'RESOLVED') { status.value = s; void load() }

async function resolve(r: OfflineReview) {
  const note = (notes.value[r.id] ?? '').trim()
  const ok = await run(async () => {
    await api().post(`/api/offline-reviews/${r.id}/resolve`, { note })
    return true
  }, 'Peninjauan diselesaikan')
  if (ok) await load()
}
</script>

<template>
  <div class="mx-auto max-w-4xl">
    <div class="mb-4 flex items-center gap-3">
      <h1 class="text-xl">Transaksi offline</h1>
      <div class="ml-auto flex gap-2" role="tablist">
        <button type="button" role="tab" :aria-selected="status === 'OPEN'" :class="['cat-chip', status === 'OPEN' ? 'cat-chip-active' : '']" @click="show('OPEN')">Perlu ditinjau</button>
        <button type="button" role="tab" :aria-selected="status === 'RESOLVED'" :class="['cat-chip', status === 'RESOLVED' ? 'cat-chip-active' : '']" @click="show('RESOLVED')">Selesai</button>
      </div>
    </div>
    <div v-if="loading" class="flex justify-center p-10"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>
    <p v-else-if="!rows.length" class="rounded-xl border border-dashed border-line p-8 text-center text-sm text-ink-soft">
      {{ status === 'OPEN' ? 'Tidak ada transaksi offline yang perlu ditinjau.' : 'Belum ada yang diselesaikan.' }}
    </p>
    <ul v-else class="space-y-3">
      <li v-for="r in rows" :key="r.id" class="rounded-xl border border-line bg-surface p-4">
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1 text-sm">
          <strong class="tabular">{{ r.receiptNo ?? 'Tanpa nomor struk' }}</strong>
          <span>Dibuat {{ new Date(r.offlineAt).toLocaleString('id-ID') }}</span>
          <span>Terkirim {{ new Date(r.submittedAt).toLocaleString('id-ID') }}</span>
        </div>
        <p class="mt-2 text-sm">Kasir offline {{ formatRupiah(r.clientTotal) }} · Server {{ formatRupiah(r.serverTotal) }}</p>
        <p class="mt-1 text-sm text-alert-600">{{ r.reason }}</p>
        <p v-if="r.resolveNote" class="mt-1 text-sm text-ink-soft">Catatan: {{ r.resolveNote }}</p>
        <div v-if="r.status === 'OPEN'" class="mt-3 flex flex-wrap items-center gap-2">
          <label :for="`n-${r.id}`" class="sr-only">Catatan peninjauan</label>
          <input :id="`n-${r.id}`" v-model="notes[r.id]" class="p-inputtext p-component min-w-[16rem] flex-1" placeholder="Catatan hasil peninjauan (min. 5 huruf)" />
          <Button label="Tandai selesai" size="small" :disabled="busy || (notes[r.id] ?? '').trim().length < 5" @click="resolve(r)" />
        </div>
      </li>
    </ul>
  </div>
</template>
