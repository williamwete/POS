<script setup lang="ts">
import type { SaleReturn } from '@/types/api'
import { formatNumber } from '@/utils/money'
import { formatBusinessDate } from '@/utils/format'

/** Bukti retur 80 mm: merujuk struk asli; nilai dari server. */
defineProps<{ ret: SaleReturn; organizationName?: string; outletName?: string }>()
const time = new Intl.DateTimeFormat('id-ID', {
  day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta',
})
const qty = (n: number) => (Number.isInteger(Number(n)) ? String(Number(n)) : Number(n).toLocaleString('id-ID', { maximumFractionDigits: 3 }))
const METHOD: Record<string, string> = { CASH: 'Tunai', DEBIT_CARD: 'Kartu debit', CREDIT_CARD: 'Kartu kredit', QRIS: 'QRIS', E_WALLET: 'E-wallet', BANK_TRANSFER: 'Transfer bank' }
</script>

<template>
  <article class="receipt-paper mx-auto bg-white p-4 font-mono text-[12px] leading-snug text-black" aria-label="Bukti retur">
    <header class="text-center">
      <div v-if="organizationName" class="text-[14px] font-bold">{{ organizationName }}</div>
      <div v-if="outletName" class="font-semibold">{{ outletName }}</div>
      <div class="mt-2 text-[14px] font-bold">BUKTI RETUR</div>
    </header>
    <hr class="my-2 border-dashed border-black" />
    <div class="flex justify-between"><span>No retur</span><span>{{ ret.returnNo }}</span></div>
    <div class="flex justify-between"><span>Struk asal</span><span>{{ ret.originalReceiptNo }}</span></div>
    <div class="flex justify-between"><span>Tanggal</span><span>{{ time.format(new Date(ret.approvedAt ?? ret.createdAt)) }}</span></div>
    <div class="flex justify-between"><span>Business date</span><span>{{ formatBusinessDate(ret.businessDate) }}</span></div>
    <div class="flex justify-between"><span>Terminal</span><span>{{ ret.terminalCode }}</span></div>
    <hr class="my-2 border-dashed border-black" />
    <div v-for="i in ret.items" :key="i.saleItemId" class="mb-1">
      <div>{{ i.productName }}</div>
      <div class="flex justify-between"><span>{{ qty(i.quantity) }} {{ i.uom }}</span><span>-{{ formatNumber(Number(i.amount)) }}</span></div>
    </div>
    <hr class="my-2 border-dashed border-black" />
    <div class="flex justify-between font-bold"><span>Total refund</span><span>{{ formatNumber(Number(ret.totalAmount)) }}</span></div>
    <div v-for="r in ret.refunds" :key="r.id" class="flex justify-between">
      <span>{{ METHOD[r.refundMethod] ?? r.refundMethod }}<template v-if="r.referenceNumber"> ({{ r.referenceNumber }})</template></span>
      <span>{{ formatNumber(Number(r.refundAmount)) }}</span>
    </div>
    <hr class="my-2 border-dashed border-black" />
    <div>Alasan: {{ ret.reason }}</div>
    <div>Disetujui: {{ ret.approvedByName ?? '-' }}</div>
    <div class="mt-6 grid grid-cols-2 gap-4 text-center">
      <div><div class="border-t border-black pt-1">Pelanggan</div></div>
      <div><div class="border-t border-black pt-1">Kasir</div></div>
    </div>
  </article>
</template>
