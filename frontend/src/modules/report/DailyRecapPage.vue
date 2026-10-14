<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import { useApiAction } from '@/composables/useApiAction'
import type { CashierSession, DashboardData } from '@/types/api'
import { formatDateTime } from '@/utils/format'
import { formatRupiah } from '@/utils/money'

const session = useSessionStore()
const { run } = useApiAction()
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
const day = ref(iso(new Date()))
const data = ref<DashboardData | null>(null)
const sessions = ref<CashierSession[]>([])
const loading = ref(true)

async function load() {
  loading.value = true
  const outletId = session.can('report.view', 'org') ? undefined : session.outletId ?? undefined
  const res = await run(async () => (await api().get<DashboardData>('/api/dashboard', { query: { from: day.value, to: day.value, outletId } })).data)
  if (res) data.value = res
  sessions.value = []
  if (session.outletId && session.can('cashier.view', session.outletId)) {
    const list = await run(async () => (await api().get<CashierSession[]>('/api/cashier/sessions', {
      query: { outletId: session.outletId, businessDate: day.value },
    })).data)
    if (list) sessions.value = list
  }
  loading.value = false
}
onMounted(load)
const print = () => window.print()

const net = computed(() => (data.value ? data.value.summary.netSales - data.value.summary.returnsTotal : 0))
const dayLabel = computed(() => new Date(day.value + 'T00:00:00').toLocaleDateString('id-ID', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }))
const diffClass = (v: number | null | undefined) => (v ? 'text-alert-600 font-medium' : '')
</script>

<template>
  <div class="mx-auto max-w-3xl">
    <div class="mb-4 flex flex-wrap items-end justify-between gap-3 print:hidden">
      <h1 class="text-xl">Rekap harian</h1>
      <div class="flex items-center gap-2">
        <label class="text-sm text-ink-soft" for="recap-day">Tanggal</label>
        <input id="recap-day" v-model="day" type="date" :max="iso(new Date())" class="p-inputtext p-component" @change="load" />
        <Button label="Cetak" icon="pi pi-print" size="small" severity="secondary" :disabled="!data" @click="print" />
      </div>
    </div>

    <div v-if="loading && !data" class="mt-16 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <article v-else-if="data" class="receipt-print recap-print rounded-xl border border-line bg-field p-6 text-sm" :aria-busy="loading">
      <header class="border-b border-line pb-3">
        <h2 class="text-lg font-bold">Rekap penjualan harian</h2>
        <p class="text-ink-soft">{{ dayLabel }}</p>
      </header>

      <section class="mt-4">
        <h3 class="font-semibold">Ringkasan</h3>
        <dl class="mt-2 grid grid-cols-[1fr_auto] gap-x-6 gap-y-1">
          <dt>Jumlah transaksi</dt><dd class="tabular text-right">{{ data.summary.salesCount.toLocaleString('id-ID') }}</dd>
          <dt>Item terjual</dt><dd class="tabular text-right">{{ Number(data.summary.itemsSold).toLocaleString('id-ID') }}</dd>
          <dt>Penjualan kotor</dt><dd class="tabular text-right">{{ formatRupiah(data.summary.grossSales) }}</dd>
          <dt>Diskon</dt><dd class="tabular text-right">− {{ formatRupiah(data.summary.discounts) }}</dd>
          <dt>Pajak</dt><dd class="tabular text-right">{{ formatRupiah(data.summary.tax) }}</dd>
          <dt class="font-medium">Penjualan bersih</dt><dd class="tabular text-right font-medium">{{ formatRupiah(data.summary.netSales) }}</dd>
          <dt>Retur ({{ data.summary.returnsCount }})</dt><dd class="tabular text-right">− {{ formatRupiah(data.summary.returnsTotal) }}</dd>
          <dt class="border-t border-line pt-1 font-bold">Omzet setelah retur</dt><dd class="tabular border-t border-line pt-1 text-right font-bold">{{ formatRupiah(net) }}</dd>
          <dt class="text-ink-soft">Void ({{ data.summary.voidCount }}, tidak dihitung)</dt><dd class="tabular text-right text-ink-soft">{{ formatRupiah(data.summary.voidTotal) }}</dd>
        </dl>
      </section>

      <section class="mt-5">
        <h3 class="font-semibold">Metode pembayaran</h3>
        <p v-if="!data.payments.length" class="mt-1 text-ink-soft">Tidak ada pembayaran.</p>
        <dl v-else class="mt-2 grid grid-cols-[1fr_auto] gap-x-6 gap-y-1">
          <template v-for="p in data.payments" :key="p.method">
            <dt>{{ p.method }} <span class="text-ink-faint">· {{ p.count }}x</span></dt><dd class="tabular text-right">{{ formatRupiah(p.amount) }}</dd>
          </template>
        </dl>
      </section>

      <section class="mt-5">
        <h3 class="font-semibold">Kasir &amp; kas</h3>
        <p v-if="!sessions.length" class="mt-1 text-ink-soft">{{ data.cash.closedSessions ? `${data.cash.closedSessions} sesi kasir ditutup.` : 'Tidak ada sesi kasir.' }}</p>
        <table v-else class="mt-2 w-full">
          <thead class="text-left text-xs text-ink-soft"><tr><th class="pb-1">Kasir</th><th class="pb-1">Status</th><th class="pb-1 text-right">Modal</th><th class="pb-1 text-right">Tutup</th><th class="pb-1 text-right">Selisih</th></tr></thead>
          <tbody>
            <tr v-for="s in sessions" :key="s.id" class="border-t border-line">
              <td class="py-1">{{ s.employeeName }}<div class="text-xs text-ink-faint">{{ s.terminalCode }} · {{ formatDateTime(s.openedAt) }}</div></td>
              <td class="py-1">{{ s.status }}</td>
              <td class="tabular py-1 text-right">{{ formatRupiah(s.openingCash) }}</td>
              <td class="tabular py-1 text-right">{{ s.closingCash == null ? '-' : formatRupiah(s.closingCash) }}</td>
              <td class="tabular py-1 text-right" :class="diffClass(s.difference)">{{ s.difference == null ? '-' : formatRupiah(s.difference) }}</td>
            </tr>
          </tbody>
        </table>
        <p v-if="data.cash.sessionsWithDifference" class="mt-2 text-alert-600">Kurang {{ formatRupiah(Math.abs(data.cash.shortTotal)) }} · lebih {{ formatRupiah(data.cash.overTotal) }} pada {{ data.cash.sessionsWithDifference }} sesi.</p>
        <p v-if="data.attention.openSessions" class="mt-2 text-amber-700">{{ data.attention.openSessions }} kasir masih terbuka.</p>
      </section>

      <section class="mt-5">
        <h3 class="font-semibold">Produk terlaris</h3>
        <p v-if="!data.topProducts.length" class="mt-1 text-ink-soft">Belum ada penjualan.</p>
        <table v-else class="mt-2 w-full">
          <tbody>
            <tr v-for="p in data.topProducts.slice(0, 5)" :key="p.sku" class="border-t border-line">
              <td class="py-1">{{ p.name }}</td>
              <td class="tabular py-1 text-right">{{ Number(p.quantity).toLocaleString('id-ID') }}</td>
              <td class="tabular py-1 text-right">{{ formatRupiah(p.revenue) }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <footer class="mt-6 border-t border-line pt-2 text-xs text-ink-faint">Dicetak {{ formatDateTime(new Date().toISOString()) }} · hanya penjualan lunas.</footer>
    </article>
  </div>
</template>

<style>
@media print {
  @page { size: A4; margin: 12mm; }
  .recap-print { width: 100% !important; font-size: 11pt; }
}
</style>
