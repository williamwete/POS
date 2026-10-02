import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type { Attendance } from '@/types/api'

/**
 * Kehadiran user yang sedang login. Semua waktu berasal dari server; store hanya menyimpan
 * hasil terakhir dan menghitung durasi tampilan.
 */
export const useAttendanceStore = defineStore('attendance', () => {
  const current = ref<Attendance | null>(null)
  const loaded = ref(false)

  const isWorking = computed(() => current.value?.status === 'WORKING')
  const isOnBreak = computed(() => current.value?.status === 'ON_BREAK')
  const openBreak = computed(() => current.value?.breaks.find((b) => !b.breakEnd) ?? null)

  async function load() {
    current.value = (await api().get<Attendance | null>('/api/attendance/current')).data ?? null
    loaded.value = true
  }

  async function clockIn(outletId: string, key: string) {
    current.value = (await api().post<Attendance>('/api/attendance/clock-in', { outletId }, { idempotencyKey: key })).data
  }

  async function startBreak(reason: string | null, key: string) {
    current.value = (await api().post<Attendance>('/api/attendance/break/start', reason ? { reason } : {}, { idempotencyKey: key })).data
  }

  async function endBreak(key: string) {
    current.value = (await api().post<Attendance>('/api/attendance/break/end', {}, { idempotencyKey: key })).data
  }

  async function clockOut(key: string) {
    await api().post<Attendance>('/api/attendance/clock-out', {}, { idempotencyKey: key })
    current.value = null
  }

  function reset() {
    current.value = null
    loaded.value = false
  }

  return { current, loaded, isWorking, isOnBreak, openBreak, load, clockIn, startBreak, endBreak, clockOut, reset }
})

/** Detik kerja bersih: sekarang/clock out − clock in − total break (termasuk break berjalan). */
export function workedSeconds(a: Attendance, now: Date): number {
  const end = a.clockOut ? new Date(a.clockOut) : now
  let breaks = 0
  for (const b of a.breaks) {
    const s = new Date(b.breakStart).getTime()
    const e = b.breakEnd ? new Date(b.breakEnd).getTime() : now.getTime()
    breaks += Math.max(0, e - s)
  }
  return Math.max(0, Math.floor((end.getTime() - new Date(a.clockIn).getTime() - breaks) / 1000))
}

export function formatDuration(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600)
  const m = Math.floor((totalSeconds % 3600) / 60)
  return `${h} j ${String(m).padStart(2, '0')} m`
}
