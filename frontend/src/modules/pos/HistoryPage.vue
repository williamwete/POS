<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import ProgressSpinner from 'primevue/progressspinner'
import { useCashierStore } from '@/stores/cashier'
import type { SessionTransaction } from '@/types/api'
import { formatRupiah } from '@/utils/money'
import ReceiptDialog from './ReceiptDialog.vue'

/** Figma "History": daftar transaksi shift ini, dicari lewat nomor, "Detail" membuka struk. */
const cashier = useCashierStore()
const router = useRouter()
const rows = ref<SessionTransaction[]>([])
const loading = ref(true)
const query = ref('')
const detailId = ref<string | null>(null)
const detailVisible = ref(false)

onMounted(async () => {
  try {
    if (!cashier.loaded) await cashier.load()
    if (!cashier.current) return void router.replace({ name: 'pos' })
    rows.value = await cashier.transactions(cashier.current.id)
  } finally {
    loading.value = false
  }
})

const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  return rows.value.filter((r) => !q || (r.receiptNo ?? '').toLowerCase().includes(q))
})
const shortNo = (n?: string | null) => (n ? `No. ${n.split('-').pop()}` : 'Tanpa nomor')
const time = (iso: string) => new Date(iso).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' })

function open(id: string) {
  detailId.value = id
  detailVisible.value = true
}
</script>

<template>
  <div class="mx-auto max-w-5xl">
    <h1 class="text-xl">History</h1>
    <div class="relative mt-3 max-w-md">
      <i class="pi pi-search pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-faint" />
      <InputText v-model="query" class="w-full !border-jade-500 !pl-9" placeholder="Search order number" aria-label="Cari nomor order" />
    </div>

    <div v-if="loading" class="mt-10 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>
    <p v-else-if="!filtered.length" class="mt-8 text-sm text-ink-soft">Belum ada transaksi pada shift ini.</p>
    <ul v-else class="mt-4 divide-y divide-line border-y border-line">
      <li v-for="r in filtered" :key="r.id" class="flex items-center justify-between gap-4 py-3">
        <div>
          <div class="font-semibold">{{ shortNo(r.receiptNo) }}</div>
          <div class="text-sm text-ink-soft">
            <span class="tabular">{{ formatRupiah(r.grandTotal) }}</span> · {{ time(r.time) }} · {{ r.paymentMethods ?? r.status }}
            <span v-if="r.status === 'VOID'" class="ml-1 text-alert-600">VOID</span>
          </div>
        </div>
        <Button label="Detail" outlined severity="secondary" size="small" @click="open(r.id)" />
      </li>
    </ul>
    <ReceiptDialog v-model:visible="detailVisible" :sale-id="detailId" />
  </div>
</template>
