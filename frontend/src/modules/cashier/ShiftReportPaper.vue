<script setup lang="ts">
import type { ShiftReport } from '@/types/api'
import { formatNumber } from '@/utils/money'
import { formatBusinessDate } from '@/utils/format'
import { DIFFERENCE_REASON_LABEL } from './cashierFormat'

/** X / Z report 80 mm (§52, §53). Semua angka dari server; tampilan ini hanya memformat. */
defineProps<{ report: ShiftReport }>()
const time = new Intl.DateTimeFormat('id-ID', {
  day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta',
})
const t = (iso?: string | null) => (iso ? time.format(new Date(iso)) : '-')
const n = (v?: number | null) => (v === null || v === undefined ? '-' : formatNumber(Number(v)))
const neg = (v?: number | null) => (v === null || v === undefined || Number(v) === 0 ? n(v) : '-' + n(v))
const signed = (v?: number | null) => {
  if (v === null || v === undefined) return '-'
  const x = Number(v)
  return (x > 0 ? '+' : x < 0 ? '-' : '') + formatNumber(Math.abs(x))
}
</script>

<template>
  <article class="receipt-paper mx-auto bg-white p-4 font-mono text-[12px] leading-snug text-black"
    :aria-label="report.reportType === 'Z' ? 'Z report' : 'X report'">
    <header class="text-center">
      <div class="text-[14px] font-bold">{{ report.header.organizationName }}</div>
      <div class="font-semibold">{{ report.header.outletName }}</div>
      <div v-if="report.header.outletAddress">{{ report.header.outletAddress }}</div>
      <div class="mt-2 text-[14px] font-bold">
        {{ report.reportType === 'Z' ? `Z REPORT #${report.zNumber}` : 'X REPORT' }}
      </div>
      <div v-if="report.reportType === 'X'">LAPORAN SEMENTARA - KASIR MASIH BUKA</div>
    </header>
    <hr class="my-2 border-dashed border-black" />
    <div class="flex justify-between"><span>Terminal</span><span>{{ report.header.terminalCode }}</span></div>
    <div class="flex justify-between"><span>Business date</span><span>{{ formatBusinessDate(report.header.businessDate) }}</span></div>
    <div class="flex justify-between"><span>Kasir</span><span>{{ report.header.cashierName }}</span></div>
    <div class="flex justify-between"><span>Session</span><span>{{ report.header.sessionId.slice(0, 8) }}</span></div>
    <div class="flex justify-between"><span>Buka</span><span>{{ t(report.header.openedAt) }}</span></div>
    <div class="flex justify-between"><span>Tutup</span><span>{{ t(report.header.closedAt) }}</span></div>

    <hr class="my-2 border-dashed border-black" />
    <div class="font-bold">PENJUALAN</div>
    <div class="flex justify-between"><span>Jumlah transaksi</span><span>{{ report.sales.transactionCount }}</span></div>
    <div class="flex justify-between"><span>Void</span><span>{{ report.sales.voidCount }}</span></div>
    <div class="flex justify-between"><span>Penjualan kotor</span><span>{{ n(report.sales.grossSales) }}</span></div>
    <div class="flex justify-between"><span>Diskon</span><span>{{ neg(report.sales.discount) }}</span></div>
    <div class="flex justify-between"><span>Refund</span><span>{{ neg(report.sales.refund) }}</span></div>
    <div class="flex justify-between font-bold"><span>Penjualan bersih</span><span>{{ n(report.sales.netSales) }}</span></div>
    <div class="flex justify-between"><span>Termasuk pajak</span><span>{{ n(report.sales.tax) }}</span></div>
    <div v-if="report.sales.openOrders > 0" class="flex justify-between"><span>Transaksi terbuka</span><span>{{ report.sales.openOrders }}</span></div>

    <hr class="my-2 border-dashed border-black" />
    <div class="font-bold">PEMBAYARAN</div>
    <div v-for="p in report.payments" :key="p.methodCode" class="flex justify-between">
      <span>{{ p.methodName }} ({{ p.count }})</span><span>{{ n(p.amount) }}</span>
    </div>

    <hr class="my-2 border-dashed border-black" />
    <div class="font-bold">KAS</div>
    <div class="flex justify-between"><span>Modal awal</span><span>{{ n(report.cash.openingCash) }}</span></div>
    <div class="flex justify-between"><span>Penjualan tunai</span><span>{{ n(report.cash.cashSales) }}</span></div>
    <div class="flex justify-between"><span>Kas masuk</span><span>{{ n(report.cash.cashIn) }}</span></div>
    <div class="flex justify-between"><span>Kas keluar</span><span>{{ neg(report.cash.cashOut) }}</span></div>
    <div class="flex justify-between"><span>Petty cash</span><span>{{ neg(report.cash.pettyCash) }}</span></div>
    <div class="flex justify-between"><span>Refund tunai</span><span>{{ neg(report.cash.cashRefund) }}</span></div>
    <div v-if="Number(report.cash.adjustment) !== 0" class="flex justify-between"><span>Penyesuaian</span><span>{{ signed(report.cash.adjustment) }}</span></div>
    <div class="flex justify-between font-bold"><span>Kas seharusnya</span><span>{{ n(report.cash.expectedCash) }}</span></div>
    <template v-if="report.reportType === 'Z'">
      <div class="flex justify-between font-bold"><span>Kas dihitung</span><span>{{ n(report.cash.actualCash) }}</span></div>
      <div class="flex justify-between font-bold"><span>Selisih</span><span>{{ signed(report.cash.difference) }}</span></div>
      <div v-if="report.cash.differenceReason">
        Alasan: {{ DIFFERENCE_REASON_LABEL[report.cash.differenceReason] }}<template v-if="report.cash.differenceNote"> - {{ report.cash.differenceNote }}</template>
      </div>

      <hr class="my-2 border-dashed border-black" />
      <div class="flex justify-between"><span>Kasir</span><span>{{ report.approval.cashierName }}</span></div>
      <div class="flex justify-between"><span>Ditutup oleh</span><span>{{ report.approval.closedByName }}</span></div>
      <div v-if="report.approval.differenceApprovedByName" class="flex justify-between">
        <span>Disetujui</span><span>{{ report.approval.differenceApprovedByName }}</span>
      </div>
      <div class="flex justify-between"><span>Waktu</span><span>{{ t(report.approval.closedAt) }}</span></div>
      <div class="mt-6 grid grid-cols-2 gap-4 text-center">
        <div><div class="border-t border-black pt-1">Kasir</div></div>
        <div><div class="border-t border-black pt-1">Supervisor</div></div>
      </div>
    </template>
    <hr class="my-2 border-dashed border-black" />
    <div class="text-center">Dibuat {{ t(report.generatedAt) }}</div>
  </article>
</template>
