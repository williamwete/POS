<script setup lang="ts">
import { onBeforeUnmount, onMounted } from 'vue'
import { useOfflineStore } from '@/stores/offline'
import { useSessionStore } from '@/stores/session'
import { NETWORK_FAILURE_EVENT } from '@/services/apiClient'
import { formatRupiah } from '@/utils/money'

/**
 * Memantau koneksi ke server (bukan hanya ke internet), mengirim antrean transaksi offline begitu
 * server terjangkau lagi, dan menampilkan statusnya. Transaksi yang ditolak server tetap tersimpan
 * di sini sampai dicoba ulang atau dibuang oleh manusia.
 */
const offline = useOfflineStore()
const session = useSessionStore()
let timer: number | undefined

async function reachable(): Promise<boolean> {
  try {
    const base = import.meta.env.VITE_API_BASE_URL ?? ''
    const ctl = new AbortController()
    const t = window.setTimeout(() => ctl.abort(), 5000)
    const res = await fetch(`${base}/actuator/health`, { cache: 'no-store', signal: ctl.signal })
    window.clearTimeout(t)
    // nginx/SPA mengembalikan HTML untuk path tak dikenal; hanya JSON dari backend yang dihitung terjangkau
    return res.ok && (res.headers.get('content-type') ?? '').includes('json')
  } catch {
    return false
  }
}

async function check() {
  const ok = await reachable()
  offline.setOnline(ok)
  if (ok && session.isAuthenticated) await offline.syncAll()
}

const goOffline = () => offline.setOnline(false)
const goOnline = () => void check()
const onFailure = () => void check()

onMounted(async () => {
  await offline.refresh()
  window.addEventListener('offline', goOffline)
  window.addEventListener('online', goOnline)
  window.addEventListener(NETWORK_FAILURE_EVENT, onFailure)
  timer = window.setInterval(() => void check(), 10_000)
  void check()
})
onBeforeUnmount(() => {
  window.removeEventListener('offline', goOffline)
  window.removeEventListener('online', goOnline)
  window.removeEventListener(NETWORK_FAILURE_EVENT, onFailure)
  window.clearInterval(timer)
})
</script>

<template>
  <div v-if="!offline.online || offline.queue.length" class="mb-4 space-y-2" role="status">
    <div v-if="!offline.online" class="rounded-lg border border-amber-500 bg-amber-100 p-3 text-sm">
      <strong>Server tidak terjangkau.</strong> Kasir berjalan dalam mode offline: hanya pembayaran tunai.
      Transaksi disimpan di perangkat ini dan dikirim otomatis begitu koneksi kembali.
    </div>
    <div v-if="offline.pending.length" class="rounded-lg border border-line bg-surface p-3 text-sm">
      <i class="pi pi-clock mr-1" aria-hidden="true" />
      <strong>{{ offline.pending.length }}</strong> transaksi offline menunggu dikirim<template v-if="offline.syncing"> (mengirim…)</template>.
      <button v-if="offline.online" type="button" class="ml-2 text-jade-700 underline" @click="offline.syncAll()">Kirim sekarang</button>
    </div>
    <div v-for="f in offline.failed" :key="f.id" class="rounded-lg border border-alert-600 bg-alert-50 p-3 text-sm text-alert-600">
      <strong>Transaksi offline ditolak server</strong> ({{ formatRupiah(f.clientTotal) }}, {{ new Date(f.offlineAt).toLocaleString('id-ID') }}):
      {{ f.error }}
      <div class="mt-2 flex gap-3">
        <button type="button" class="underline" @click="offline.retry(f.id)">Coba lagi</button>
        <button type="button" class="underline" @click="offline.discard(f.id)">Buang</button>
      </div>
    </div>
  </div>
</template>
