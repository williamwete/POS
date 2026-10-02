import type { Attendance, AttendanceStatus } from '@/types/api'
import { formatDuration, workedSeconds } from '@/stores/attendance'

export const STATUS_LABEL: Record<AttendanceStatus, string> = {
  WORKING: 'Bekerja',
  ON_BREAK: 'Istirahat',
  COMPLETED: 'Selesai',
  FORCED_CLOSED: 'Ditutup supervisor',
}

export const STATUS_CLASS: Record<AttendanceStatus, string> = {
  WORKING: 'bg-jade-50 text-jade-700',
  ON_BREAK: 'bg-amber-100 text-amber-700',
  COMPLETED: 'bg-field text-ink-soft',
  FORCED_CLOSED: 'bg-alert-50 text-alert-600',
}

const time = new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' })

export function clockTime(iso?: string | null): string {
  return iso ? time.format(new Date(iso)) : '—'
}

export function workedLabel(a: Attendance, now: Date): string {
  return formatDuration(workedSeconds(a, now))
}

export function breakLabel(a: Attendance, now: Date): string {
  let total = 0
  for (const b of a.breaks) {
    const end = b.breakEnd ? new Date(b.breakEnd).getTime() : now.getTime()
    total += Math.max(0, end - new Date(b.breakStart).getTime())
  }
  return a.breaks.length ? `${formatDuration(Math.floor(total / 1000))} (${a.breaks.length}×)` : '—'
}
