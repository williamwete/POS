<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import { useApiAction } from '@/composables/useApiAction'
import type { SalesReport, SalesReportGroup } from '@/types/api'
import { toCsv } from '@/utils/csv'
import { formatRupiah } from '@/utils/money'

const session = useSessionStore()
const { run } = useApiAction()
const data = ref<SalesReport | null>(null)
const loading = ref(true)
const preset = ref<'today' | '7' | '30' | 'month'>('7')
const group = ref<SalesReportGroup>('PRODUCT')

const groups: [SalesReportGroup, string, string][] = [
  ['PRODUCT', 'Per produk', 'Produk'], ['CATEGORY', 'Per kategori', 'Kategori'], ['CASHIER', 'Per kasir', 'Kasir'],
  ['DAY', 'Per hari', 'Tanggal'], ['PAYMENT', 'Per metode bayar', 'Metode'],
]
const presets = [['today', 'Hari ini'], ['7', '7 hari'], ['30', '30 hari'], ['month', 'Bulan ini']] as const
const firstColumn = computed(() => groups.find((g) => g[0] === group.value)![2])
const hasItems = computed(() => group.value !== 'PAYMENT')

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
function range(): [string, string] {
  const to = new Date()
  const from = new Date()
  if (preset.value === 'today') return [iso(to), iso(to)]
  if (preset.value === 'month') from.setDate(1)
  else from.setDate(from.getDate() - (Number(preset.value) - 1))
  return [iso(from), iso(to)]
}

async function load() {
  loading.value = true
  const [from, to] = range()
  const res = await run(async () => (await api().get<SalesReport>('/api/reports/sales', {
    query: { from, to, group: group.value, outletId: session.can('report.view', 'org') ? undefined : session.outletId ?? undefined },
  })).data)
  if (res) data.value = res
  loading.value = false
}
onMounted(load)
function choosePreset(p: typeof preset.value) { preset.value = p; void load() }
function chooseGroup(g: SalesReportGroup) { group.value = g; void load() }

const total = computed(() => (data.value?.rows ?? []).reduce((a, r) => a + r.net, 0))
const num = (v: number | null) => (v === null ? '' : Number(v).toLocaleString('id-ID'))
const money = (v: number | null) => (v === null ? '' : formatRupiah(v))

function download() {
  if (!data.value) return
  const rows = data.value.rows
  const header = hasItems.value
    ? [firstColumn.value, 'Kode', 'Transaksi', 'Jumlah item', 'Penjualan kotor', 'Diskon', 'Penjualan bersih']
    : [firstColumn.value, 'Kode', 'Transaksi', '', '', '', 'Nilai']
  const body = rows.map((r) => [r.label, r.key, r.transactions, r.quantity, r.gross, r.discount, r.net])
  const csv = toCsv(header, body)
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = `laporan-${group.value.toLowerCase()}-${data.value.from}_${data.value.to}.csv`
  a.click()
  URL.revokeObjectURL(url)
}
</script>

<template>
  <div class="mx-auto max-w-6xl">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <h1 class="text-xl">Laporan penjualan</h1>
      <div class="flex flex-wrap gap-2">
        <div class="flex gap-2" role="group" aria-label="Rentang waktu">
          <Button v-for="[k, label] in presets" :key="k" :label="label" size="small" :severity="preset === k ? undefined : 'secondary'"
            :outlined="preset !== k" @click="choosePreset(k)" />
        </div>
        <Button label="Unduh CSV" icon="pi pi-download" size="small" severity="secondary" :disabled="!data || !data.rows.length" @click="download" />
      </div>
    </div>

    <div class="mt-4 flex flex-wrap gap-2" role="tablist" aria-label="Kelompokkan laporan">
      <Button v-for="[k, label] in groups" :key="k" :label="label" size="small" role="tab" :aria-selected="group === k"
        :severity="group === k ? undefined : 'secondary'" :outlined="group !== k" @click="chooseGroup(k)" />
    </div>

    <div v-if="loading && !data" class="mt-16 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <section v-else-if="data" class="mt-4 rounded-xl border border-line bg-field p-4" :aria-busy="loading">
      <p v-if="!data.rows.length" class="text-sm text-ink-soft">Belum ada penjualan lunas pada rentang ini.</p>
      <div v-else class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-xs text-ink-soft">
            <tr>
              <th class="pb-1">{{ firstColumn }}</th>
              <th class="pb-1 text-right">Transaksi</th>
              <th v-if="hasItems" class="pb-1 text-right">Item</th>
              <th v-if="hasItems" class="pb-1 text-right">Kotor</th>
              <th v-if="hasItems" class="pb-1 text-right">Diskon</th>
              <th class="pb-1 text-right">{{ hasItems ? 'Bersih' : 'Nilai' }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in data.rows" :key="r.key" class="border-t border-line">
              <td class="py-1.5">{{ r.label }}<div v-if="group === 'PRODUCT'" class="text-xs text-ink-faint">{{ r.key }}</div></td>
              <td class="tabular py-1.5 text-right">{{ num(r.transactions) }}</td>
              <td v-if="hasItems" class="tabular py-1.5 text-right">{{ num(r.quantity) }}</td>
              <td v-if="hasItems" class="tabular py-1.5 text-right">{{ money(r.gross) }}</td>
              <td v-if="hasItems" class="tabular py-1.5 text-right">{{ money(r.discount) }}</td>
              <td class="tabular py-1.5 text-right font-medium">{{ money(r.net) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr class="border-t-2 border-line font-semibold">
              <td class="pt-2" :colspan="hasItems ? 5 : 2">Total</td>
              <td class="tabular pt-2 text-right">{{ formatRupiah(total) }}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      <p class="mt-3 text-xs text-ink-faint">Hanya penjualan yang sudah lunas; void tidak dihitung. Retur ditampilkan di Dashboard.</p>
    </section>
  </div>
</template>
