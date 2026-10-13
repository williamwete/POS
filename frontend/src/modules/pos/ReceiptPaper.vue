<script setup lang="ts">
import type { Receipt } from '@/types/api'
import { formatNumber } from '@/utils/money'
import { formatBusinessDate } from '@/utils/format'
import { useBrandStore } from '@/stores/brand'

const brand = useBrandStore()

/** Struk 80 mm (§30). Dipakai untuk pratinjau dan cetak (thermal via dialog print browser). */
const props = defineProps<{ receipt: Receipt }>()
const time = new Intl.DateTimeFormat('id-ID', {
  day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta',
})
const qty = (n: number) => (Number.isInteger(n) ? String(n) : n.toLocaleString('id-ID', { maximumFractionDigits: 3 }))
const unpaid = () => props.receipt.status !== 'PAID' && props.receipt.status !== 'POSTED'
</script>

<template>
  <article class="receipt-paper mx-auto bg-white p-4 font-mono text-[12px] leading-snug text-black" aria-label="Struk" :style="{ '--paper': `${receipt.paperWidthMm ?? 80}mm` }">
    <header class="text-center">
      <img v-if="brand.logo" :src="brand.logo" alt="" class="mx-auto mb-1 max-h-14 max-w-[40mm] object-contain grayscale" />
      <div class="text-[14px] font-bold">{{ receipt.organizationName }}</div>
      <div class="font-semibold">{{ receipt.outletName }}</div>
      <div v-if="receipt.outletAddress">{{ receipt.outletAddress }}</div>
      <div v-if="receipt.outletPhone">Telp {{ receipt.outletPhone }}</div>
      <div v-if="receipt.taxId">NPWP {{ receipt.taxId }}</div>
      <div v-if="receipt.headerText" class="mt-1">{{ receipt.headerText }}</div>
    </header>
    <hr class="my-2 border-dashed border-black" />
    <div class="flex justify-between"><span>No</span><span>{{ receipt.receiptNo }}</span></div>
    <div class="flex justify-between"><span>Tanggal</span><span>{{ receipt.issuedAt ? time.format(new Date(receipt.issuedAt)) : '' }}</span></div>
    <div class="flex justify-between"><span>Business date</span><span>{{ formatBusinessDate(receipt.businessDate) }}</span></div>
    <div class="flex justify-between"><span>Terminal</span><span>{{ receipt.terminalCode }}</span></div>
    <div v-if="receipt.showCashier !== false" class="flex justify-between"><span>Kasir</span><span>{{ receipt.cashierName }}</span></div>
    <hr class="my-2 border-dashed border-black" />
    <div v-for="(l, i) in receipt.lines" :key="i" class="mb-1">
      <div>{{ l.name }}</div>
      <div v-if="l.options" class="pl-2">+ {{ l.options }}</div>
      <div class="flex justify-between">
        <span>{{ qty(l.quantity) }} {{ l.uom }} × {{ formatNumber(l.unitPrice) }}<template v-if="l.unitPrice !== l.listPrice"> (normal {{ formatNumber(l.listPrice) }})</template></span>
        <span>{{ formatNumber(l.amount + l.discount) }}</span>
      </div>
      <div v-if="l.discount > 0" class="flex justify-between"><span>&nbsp;&nbsp;Diskon</span><span>-{{ formatNumber(l.discount) }}</span></div>
    </div>
    <hr class="my-2 border-dashed border-black" />
    <div class="flex justify-between"><span>Subtotal ({{ qty(receipt.itemCount) }} item)</span><span>{{ formatNumber(receipt.subtotal) }}</span></div>
    <div v-if="receipt.discountTotal > 0" class="flex justify-between"><span>Total diskon</span><span>-{{ formatNumber(receipt.discountTotal) }}</span></div>
    <div v-if="receipt.showTaxDetail !== false" class="flex justify-between"><span>Pajak{{ receipt.pricesIncludeTax ? ' (termasuk)' : '' }}</span><span>{{ formatNumber(receipt.taxTotal) }}</span></div>
    <div class="mt-1 flex justify-between text-[15px] font-bold"><span>TOTAL</span><span>{{ formatNumber(receipt.grandTotal) }}</span></div>
    <template v-if="!unpaid() && receipt.payments?.length">
      <hr class="my-2 border-dashed border-black" />
      <div v-for="(p, i) in receipt.payments" :key="i">
        <div class="flex justify-between">
          <span>{{ p.methodName }}</span>
          <span>{{ formatNumber(p.methodKind === 'CASH' ? p.amountReceived : p.amount) }}</span>
        </div>
        <div v-if="p.referenceNumber" class="pl-2">Ref {{ p.referenceNumber }}</div>
      </div>
      <div class="mt-1 flex justify-between font-bold"><span>KEMBALI</span><span>{{ formatNumber(receipt.changeAmount) }}</span></div>
    </template>
    <hr class="my-2 border-dashed border-black" />
    <p v-if="unpaid()" class="text-center font-bold">*** BELUM DIBAYAR — BUKAN BUKTI PEMBAYARAN ***</p>
    <p v-else class="text-center"><span class="font-bold">LUNAS</span> — {{ receipt.footerText || 'Terima kasih' }}</p>
    <p v-if="receipt.printCount > 1" class="mt-1 text-center">CETAK ULANG #{{ receipt.printCount - 1 }}</p>
  </article>
</template>

<style scoped>
.receipt-paper {
  width: var(--paper, 80mm);
  max-width: 100%;
}
</style>
