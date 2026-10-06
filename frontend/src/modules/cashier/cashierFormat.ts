import type { CashierSessionStatus, CashMovementType, DifferenceReason, LockReason } from '@/types/api'
import { formatRupiah } from '@/utils/money'

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

export const DIFFERENCE_REASON_LABEL: Record<DifferenceReason, string> = {
  SHORTAGE: 'Uang kurang',
  OVERAGE: 'Uang lebih',
  WRONG_CHANGE: 'Salah kembalian',
  COUNTING_ERROR: 'Salah hitung',
  OTHER: 'Lainnya',
}

export const MOVEMENT_TYPE_LABEL: Record<CashMovementType, string> = {
  OPENING_CASH: 'Modal awal',
  CASH_SALE: 'Penjualan tunai',
  CASH_SALE_REVERSAL: 'Pembatalan tunai',
  CASH_IN: 'Kas masuk',
  CASH_OUT: 'Kas keluar',
  PETTY_CASH: 'Petty cash',
  CASH_REFUND: 'Refund tunai',
  CASH_ADJUSTMENT: 'Penyesuaian',
  CLOSING_CASH: 'Setor tutup kasir',
}

/** Rupiah bertanda: +Rp 5.000 / −Rp 5.000. */
export function signedRupiah(n?: number | null): string {
  if (n === null || n === undefined) return '—'
  const v = Number(n)
  if (v === 0) return formatRupiah(0)
  return (v > 0 ? '+' : '−') + formatRupiah(Math.abs(v))
}
