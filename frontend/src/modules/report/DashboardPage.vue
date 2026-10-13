<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import { useApiAction } from '@/composables/useApiAction'
import type { DashboardData } from '@/types/api'
import { formatRupiah } from '@/utils/money'

const session = useSessionStore()
const { run } = useApiAction()
const data = ref<DashboardData | null>(null)
const loading = ref(true)
const preset = ref<'today' | '7' | '30' | 'month'>('7')

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
function range() {
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
  const res = await run(async () => (await api().get<DashboardData>('/api/dashboard', {
    query: { from, to, outletId: session.can('report.view', 'org') ? undefined : session.outletId ?? undefined },
  })).data)
  if (res) data.value = res
  loading.value = false
}
onMounted(load)
function choose(p: typeof preset.value) { preset.value = p; void load() }

const presets = [['today', 'Hari ini'], ['7', '7 hari'], ['30', '30 hari'], ['month', 'Bulan ini']] as const
const maxDaily = computed(() => Math.max(1, ...(data.value?.daily ?? []).map((d) => d.total)))
const maxHour = computed(() => Math.max(1, ...(data.value?.hourly ?? []).map((d) => d.total)))
const payTotal = computed(() => Math.max(1, (data.value?.payments ?? []).reduce((a, p) => a + p.amount, 0)))
const maxCat = computed(() => Math.max(1, ...(data.value?.categories ?? []).map((c) => c.revenue)))
const dayLabel = (d: string) => new Date(d + 'T00:00:00').toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })
const pct = (v: number, max: number) => `${Math.max(2, Math.round((v / max) * 100))}%`
const net = computed(() => (data.value ? data.value.summary.netSales - data.value.summary.returnsTotal : 0))
</script>

<template>
  <div class="mx-auto max-w-6xl">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <h1 class="text-xl">Dashboard</h1>
      <div class="flex gap-2" role="group" aria-label="Rentang waktu">
        <Button v-for="[k, label] in presets" :key="k" :label="label" size="small" :severity="preset === k ? undefined : 'secondary'"
          :outlined="preset !== k" @click="choose(k)" />
      </div>
    </div>

    <div v-if="loading && !data" class="mt-16 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <template v-else-if="data">
      <div v-if="data.attention.syncProblems || data.attention.openSessions || data.cash.sessionsWithDifference" class="mt-4 flex flex-wrap gap-2 text-sm">
        <span v-if="data.attention.openSessions" class="rounded-full bg-amber-100 px-3 py-1">{{ data.attention.openSessions }} kasir masih terbuka</span>
        <span v-if="data.attention.syncProblems" class="rounded-full bg-alert-50 px-3 py-1 text-alert-600">{{ data.attention.syncProblems }} transaksi gagal sinkron</span>
        <span v-if="data.cash.sessionsWithDifference" class="rounded-full bg-amber-100 px-3 py-1">{{ data.cash.sessionsWithDifference }} closing dengan selisih kas</span>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div class="rounded-xl border border-line bg-field p-4"><div class="text-xs text-ink-soft">Omzet bersih</div><div class="tabular mt-1 text-2xl font-bold text-jade-700">{{ formatRupiah(net) }}</div><div class="text-xs text-ink-faint">sudah dikurangi retur {{ formatRupiah(data.summary.returnsTotal) }}</div></div>
        <div class="rounded-xl border border-line bg-field p-4"><div class="text-xs text-ink-soft">Transaksi</div><div class="tabular mt-1 text-2xl font-bold">{{ data.summary.salesCount.toLocaleString('id-ID') }}</div><div class="text-xs text-ink-faint">{{ Number(data.summary.itemsSold).toLocaleString('id-ID') }} item terjual</div></div>
        <div class="rounded-xl border border-line bg-field p-4"><div class="text-xs text-ink-soft">Rata-rata per transaksi</div><div class="tabular mt-1 text-2xl font-bold">{{ formatRupiah(data.summary.avgBasket) }}</div><div class="text-xs text-ink-faint">diskon {{ formatRupiah(data.summary.discounts) }}</div></div>
        <div class="rounded-xl border border-line bg-field p-4"><div class="text-xs text-ink-soft">Void</div><div class="tabular mt-1 text-2xl font-bold">{{ data.summary.voidCount }}</div><div class="text-xs text-ink-faint">{{ formatRupiah(data.summary.voidTotal) }} · pajak {{ formatRupiah(data.summary.tax) }}</div></div>
      </div>

      <section class="mt-4 rounded-xl border border-line bg-field p-4" aria-labelledby="daily-title">
        <h2 id="daily-title" class="text-base font-semibold">Penjualan harian</h2>
        <div class="mt-3 flex h-40 items-end gap-1" role="img" :aria-label="`Grafik penjualan ${data.daily.length} hari`">
          <div v-for="d in data.daily" :key="d.date" class="flex h-full min-w-0 flex-1 flex-col justify-end" :title="`${dayLabel(d.date)}: ${formatRupiah(d.total)} (${d.count} transaksi)`">
            <div class="w-full rounded-t bg-jade-500" :style="{ height: d.total ? pct(d.total, maxDaily) : '0%' }" />
          </div>
        </div>
        <div class="mt-1 flex justify-between text-xs text-ink-faint"><span>{{ dayLabel(data.daily[0]!.date) }}</span><span>{{ dayLabel(data.daily[data.daily.length - 1]!.date) }}</span></div>
      </section>

      <div class="mt-4 grid gap-4 lg:grid-cols-2">
        <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="hour-title">
          <h2 id="hour-title" class="text-base font-semibold">Jam ramai</h2>
          <div class="mt-3 flex h-28 items-end gap-0.5" role="img" aria-label="Penjualan per jam">
            <div v-for="h in data.hourly" :key="h.hour" class="flex h-full flex-1 flex-col justify-end" :title="`${String(h.hour).padStart(2, '0')}:00 — ${formatRupiah(h.total)} (${h.count})`">
              <div class="w-full rounded-t bg-jade-500/50" :style="{ height: h.total ? pct(h.total, maxHour) : '0%' }" />
            </div>
          </div>
          <div class="mt-1 flex justify-between text-xs text-ink-faint"><span>00</span><span>06</span><span>12</span><span>18</span><span>23</span></div>
        </section>

        <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="pay-title">
          <h2 id="pay-title" class="text-base font-semibold">Metode pembayaran</h2>
          <p v-if="!data.payments.length" class="mt-3 text-sm text-ink-soft">Belum ada pembayaran.</p>
          <ul v-else class="mt-3 space-y-3">
            <li v-for="p in data.payments" :key="p.method">
              <div class="flex justify-between text-sm"><span>{{ p.method }} <span class="text-ink-faint">· {{ p.count }}x</span></span><span class="tabular">{{ formatRupiah(p.amount) }}</span></div>
              <div class="mt-1 h-2 rounded bg-line"><div class="h-2 rounded bg-jade-500" :style="{ width: pct(p.amount, payTotal) }" /></div>
            </li>
          </ul>
        </section>

        <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="top-title">
          <h2 id="top-title" class="text-base font-semibold">Produk terlaris</h2>
          <p v-if="!data.topProducts.length" class="mt-3 text-sm text-ink-soft">Belum ada penjualan.</p>
          <table v-else class="mt-3 w-full text-sm">
            <thead class="text-left text-xs text-ink-soft"><tr><th class="pb-1">Produk</th><th class="pb-1 text-right">Jumlah</th><th class="pb-1 text-right">Omzet</th></tr></thead>
            <tbody>
              <tr v-for="p in data.topProducts" :key="p.sku" class="border-t border-line">
                <td class="py-1.5">{{ p.name }}<div class="text-xs text-ink-faint">{{ p.sku }}</div></td>
                <td class="tabular py-1.5 text-right">{{ Number(p.quantity).toLocaleString('id-ID') }}</td>
                <td class="tabular py-1.5 text-right">{{ formatRupiah(p.revenue) }}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <div class="space-y-4">
          <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="cat-title">
            <h2 id="cat-title" class="text-base font-semibold">Omzet per kategori</h2>
            <p v-if="!data.categories.length" class="mt-3 text-sm text-ink-soft">Belum ada penjualan.</p>
            <ul v-else class="mt-3 space-y-2">
              <li v-for="c in data.categories" :key="c.name">
                <div class="flex justify-between text-sm"><span>{{ c.name }}</span><span class="tabular">{{ formatRupiah(c.revenue) }}</span></div>
                <div class="mt-1 h-2 rounded bg-line"><div class="h-2 rounded bg-jade-500/50" :style="{ width: pct(c.revenue, maxCat) }" /></div>
              </li>
            </ul>
          </section>

          <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="cash-title">
            <h2 id="cash-title" class="text-base font-semibold">Closing kasir</h2>
            <dl class="mt-3 grid grid-cols-2 gap-2 text-sm">
              <dt class="text-ink-soft">Sesi ditutup</dt><dd class="tabular text-right">{{ data.cash.closedSessions }}</dd>
              <dt class="text-ink-soft">Sesi dengan selisih</dt><dd class="tabular text-right">{{ data.cash.sessionsWithDifference }}</dd>
              <dt class="text-ink-soft">Total kurang</dt><dd class="tabular text-right text-alert-600">{{ formatRupiah(data.cash.shortTotal) }}</dd>
              <dt class="text-ink-soft">Total lebih</dt><dd class="tabular text-right">{{ formatRupiah(data.cash.overTotal) }}</dd>
            </dl>
          </section>

          <section class="rounded-xl border border-line bg-field p-4" aria-labelledby="stock-title">
            <h2 id="stock-title" class="text-base font-semibold">Stok menipis (≤ 5)</h2>
            <p v-if="!data.lowStock.length" class="mt-3 text-sm text-ink-soft">Tidak ada produk yang menipis.</p>
            <ul v-else class="mt-3 space-y-1 text-sm">
              <li v-for="s in data.lowStock" :key="s.sku" class="flex justify-between"><span>{{ s.name }}</span><span class="tabular" :class="Number(s.available) <= 0 ? 'text-alert-600' : ''">{{ Number(s.available).toLocaleString('id-ID') }}</span></li>
            </ul>
          </section>
        </div>
      </div>
    </template>
  </div>
</template>
