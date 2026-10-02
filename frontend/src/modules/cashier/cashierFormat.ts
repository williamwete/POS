import type { CashierSessionStatus, LockReason } from '@/types/api'

export const SESSION_STATUS_LABEL: Record<CashierSessionStatus, string> = {
  OPEN: 'Buka',
  ON_BREAK: 'Terkunci',
  CLOSING: 'Proses tutup',
  CLOSED: 'Tutup',
  CANCELLED: 'Dibatalkan',
}

export const SESSION_STATUS_CLASS: Record<CashierSessionStatus, string> = {
  OPEN: 'bg-jade-50 text-jade-700',
  ON_BREAK: 'bg-amber-100 text-amber-700',
  CLOSING: 'bg-amber-100 text-amber-700',
  CLOSED: 'bg-field text-ink-soft',
  CANCELLED: 'bg-alert-50 text-alert-600',
}

export const LOCK_REASON_LABEL: Record<LockReason, string> = {
  MANUAL: 'dikunci kasir',
  IDLE: 'tidak ada aktivitas',
  BREAK: 'istirahat',
  FORCED_CLOCK_OUT: 'kehadiran ditutup supervisor',
}

export const COUNT_TYPE_LABEL: Record<string, string> = {
  OPENING: 'Modal awal',
  MID: 'Hitung tengah shift',
  CLOSING: 'Tutup kasir',
  HANDOVER: 'Serah terima',
}
