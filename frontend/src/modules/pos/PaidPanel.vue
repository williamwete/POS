<script setup lang="ts">
import { computed, onMounted } from 'vue'
import Button from 'primevue/button'
import { useSaleStore } from '@/stores/sale'
import { usePaymentStore } from '@/stores/payment'
import { useSessionStore } from '@/stores/session'
import { formatRupiah } from '@/utils/money'

/** Figma "Payment Success": centang, total, metode/ref/kasir, See Receipt, New Transaction. */
const emit = defineEmits<{ receipt: []; next: [] }>()
const sales = useSaleStore()
const payments = usePaymentStore()
const session = useSessionStore()
onMounted(() => {
  if (sales.sale && !payments.payments.length) void payments.load(sales.sale.id).catch(() => undefined)
})
const paid = computed(() => payments.payments.filter((p) => p.status === 'PAID'))
const method = computed(() => paid.value.map((p) => (p.methodKind === 'CASH' ? 'Cash' : `Cashless · ${p.methodName}`)).join(' + '))
const refNo = computed(() => paid.value.map((p) => p.referenceNumber).filter(Boolean).join(', '))
const when = computed(() => new Date().toLocaleString('en-GB', { day: 'numeric', month: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' }))
</script>

<template>
  <section v-if="sales.sale" class="px-2 pb-2 text-center" aria-live="polite">
    <div class="mx-auto mt-2 grid h-28 w-28 place-items-center rounded-full border-4 border-jade-500 text-jade-500">
      <i class="pi pi-check text-5xl" aria-hidden="true" />
    </div>
    <h2 class="mt-4 text-xl font-semibold">Payment Success</h2>
    <p class="tabular text-3xl font-bold">{{ formatRupiah(sales.sale.grandTotal) }}</p>
    <p class="mt-2 text-xs text-ink-faint">No. {{ sales.sale.receiptNo?.split('-').pop() }}<br />{{ when }}</p>
    <dl class="mt-4 space-y-1 rounded-lg border border-line p-3 text-left text-sm">
      <div class="flex justify-between"><dt>Method</dt><dd class="font-semibold">{{ method }}</dd></div>
      <div v-if="refNo" class="flex justify-between"><dt>Ref</dt><dd class="tabular">{{ refNo }}</dd></div>
      <div v-if="sales.sale.changeAmount > 0" class="flex justify-between"><dt>Change</dt><dd class="tabular font-semibold">{{ formatRupiah(sales.sale.changeAmount) }}</dd></div>
      <div class="flex justify-between"><dt>Cashier</dt><dd>{{ session.me?.user.displayName }}</dd></div>
    </dl>
    <Button label="See Receipt" severity="secondary" outlined class="mt-4 w-full" @click="emit('receipt')" />
    <Button label="New Transaction" class="mt-3 w-full" @click="emit('next')" />
  </section>
</template>
