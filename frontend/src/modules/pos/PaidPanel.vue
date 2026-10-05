<script setup lang="ts">
import { onMounted } from 'vue'
import Button from 'primevue/button'
import { useSaleStore } from '@/stores/sale'
import { usePaymentStore } from '@/stores/payment'
import { formatRupiah } from '@/utils/money'

/** Transaksi lunas: kembalian besar & jelas untuk kasir, lalu cetak struk dan transaksi baru. */
const emit = defineEmits<{ receipt: []; next: [] }>()
const sales = useSaleStore()
const payments = usePaymentStore()
onMounted(() => {
  if (sales.sale && !payments.payments.length) void payments.load(sales.sale.id).catch(() => undefined)
})
</script>

<template>
  <section v-if="sales.sale" class="overflow-hidden rounded-lg border-2 border-jade-600 bg-surface" aria-live="polite">
    <div class="bg-jade-700 px-4 py-4 text-white">
      <p class="text-xs font-semibold uppercase tracking-wide text-jade-100">Lunas</p>
      <p class="tabular text-lg font-bold">{{ sales.sale.receiptNo }}</p>
    </div>
    <div class="p-4">
      <p class="text-sm text-ink-soft">Kembalian</p>
      <p class="tabular text-5xl font-bold tracking-tight text-jade-700">{{ formatRupiah(sales.sale.changeAmount) }}</p>
      <ul class="mt-4 space-y-1 text-sm">
        <li v-for="p in payments.payments.filter((x) => x.status === 'PAID')" :key="p.id" class="flex justify-between">
          <span>{{ p.methodName }}<template v-if="p.methodKind === 'CASH'"> (diterima {{ formatRupiah(p.amountReceived) }})</template></span>
          <span class="tabular font-semibold">{{ formatRupiah(p.amount) }}</span>
        </li>
      </ul>
      <div class="mt-5 grid gap-2">
        <Button label="Cetak struk" icon="pi pi-print" size="large" @click="emit('receipt')" />
        <Button label="Transaksi baru (F2)" icon="pi pi-plus" severity="secondary" outlined @click="emit('next')" />
      </div>
    </div>
  </section>
</template>
