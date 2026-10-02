<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import { formatDuration, useAttendanceStore } from '@/stores/attendance'
import { useApiAction } from '@/composables/useApiAction'

/**
 * Layar kunci saat istirahat (§12: "POS dapat dikunci, kasir tidak boleh bertransaksi").
 * Ini hanya UX; backend menolak transaksi saat status ON_BREAK mulai Phase 4.
 */
const attendance = useAttendanceStore()
const { busy, run } = useApiAction()
const now = ref(new Date())
let timer: number | undefined
onMounted(() => (timer = window.setInterval(() => (now.value = new Date()), 1000)))
onBeforeUnmount(() => window.clearInterval(timer))

const elapsed = computed(() => {
  const b = attendance.openBreak
  if (!b) return ''
  return formatDuration(Math.floor((now.value.getTime() - new Date(b.breakStart).getTime()) / 1000))
})
const since = computed(() => {
  const b = attendance.openBreak
  return b ? new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' }).format(new Date(b.breakStart)) : ''
})

function endBreak() {
  void run((key) => attendance.endBreak(key), 'Selamat bekerja kembali')
}
</script>

<template>
  <div
    v-if="attendance.isOnBreak"
    class="fixed inset-0 z-50 flex items-center justify-center bg-jade-900/95 p-6 text-white"
    role="dialog"
    aria-modal="true"
    aria-labelledby="break-title"
  >
    <div class="max-w-md text-center">
      <i class="pi pi-pause-circle text-5xl text-amber-500" aria-hidden="true" />
      <h2 id="break-title" class="mt-4 text-3xl font-bold">Sedang istirahat</h2>
      <p class="mt-2 text-jade-100">
        Sejak <span class="tabular font-semibold text-white">{{ since }}</span>
        <template v-if="attendance.openBreak?.reason"> · {{ attendance.openBreak.reason }}</template>
      </p>
      <p class="tabular mt-6 text-5xl font-bold tracking-tight">{{ elapsed }}</p>
      <p class="mt-6 text-sm text-jade-100">POS terkunci selama istirahat. Transaksi tidak dapat dibuat.</p>
      <Button class="mt-6" label="Selesai istirahat" icon="pi pi-play" size="large" :loading="busy" @click="endBreak" />
    </div>
  </div>
</template>
