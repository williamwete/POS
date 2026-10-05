import type { PaymentStatus } from '@/types/api'

export const PAYMENT_STATUS_LABEL: Record<PaymentStatus, string> = {
  PENDING: 'Menunggu',
  PAID: 'Berhasil',
  FAILED: 'Gagal',
  CANCELLED: 'Dibatalkan',
  REFUNDED: 'Dikembalikan',
}

export const PAYMENT_STATUS_CLASS: Record<PaymentStatus, string> = {
  PENDING: 'bg-amber-100 text-amber-700',
  PAID: 'bg-jade-50 text-jade-700',
  FAILED: 'bg-alert-50 text-alert-600',
  CANCELLED: 'bg-field text-ink-soft',
  REFUNDED: 'bg-field text-ink-soft',
}

export const KIND_ICON: Record<string, string> = {
  CASH: 'pi pi-money-bill',
  CARD: 'pi pi-credit-card',
  QRIS: 'pi pi-qrcode',
  EWALLET: 'pi pi-mobile',
  TRANSFER: 'pi pi-building-columns',
  OTHER: 'pi pi-wallet',
}

export function referenceLabel(kind: string): string {
  if (kind === 'CARD') return 'Kode approval / trace EDC'
  if (kind === 'TRANSFER') return 'No. referensi transfer'
  return 'No. referensi pembayaran'
}
