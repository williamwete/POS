<script setup lang="ts">
import { computed } from 'vue'
import InputNumber from 'primevue/inputnumber'
import type { Denomination } from '@/types/api'
import { countTotal, formatNumber, formatRupiah } from '@/utils/money'

/**
 * Hitung uang per denominasi (§14). Total di sini hanya pratinjau; server menghitung ulang
 * dari master denominasi dan nilai server yang tersimpan.
 */
const props = defineProps<{ denominations: Denomination[]; idPrefix?: string }>()
const quantities = defineModel<Record<string, number | null>>({ required: true })

const notes = computed(() => props.denominations.filter((d) => d.kind === 'NOTE'))
const coins = computed(() => props.denominations.filter((d) => d.kind === 'COIN'))
const values = computed(() => new Map(props.denominations.map((d) => [d.id, d.value])))
const total = computed(() => countTotal(values.value, quantities.value))
const pieces = computed(() => Object.values(quantities.value).reduce<number>((n, q) => n + (q && q > 0 ? q : 0), 0))

function subtotal(d: Denomination): number {
  const q = quantities.value[d.id]
  return q && q > 0 ? d.value * q : 0
}

function setQty(id: string, q: number | null) {
  quantities.value = { ...quantities.value, [id]: q }
}

const groups = computed(() => [
  { key: 'NOTE', label: 'Uang kertas', items: notes.value },
  { key: 'COIN', label: 'Koin', items: coins.value },
])
</script>

<template>
  <div>
    <div class="grid gap-6 lg:grid-cols-2">
      <fieldset v-for="g in groups" :key="g.key" class="min-w-0">
        <legend class="mb-2 text-sm font-semibold text-ink-soft">{{ g.label }}</legend>
        <ul class="divide-y divide-line overflow-hidden rounded-lg border border-line bg-surface">
          <li v-for="d in g.items" :key="d.id" class="flex items-center gap-2 px-2 py-2 sm:gap-3 sm:px-3">
            <label
              :for="`${idPrefix ?? 'den'}-${d.id}`"
              :class="[
                'denom tabular w-20 shrink-0 rounded px-2 py-1 text-right text-sm font-bold sm:w-24',
                d.kind === 'NOTE' ? 'denom-note' : 'denom-coin',
              ]"
            >
              {{ formatNumber(d.value) }}
            </label>
            <span class="hidden text-ink-faint sm:inline" aria-hidden="true">×</span>
            <InputNumber
              :input-id="`${idPrefix ?? 'den'}-${d.id}`"
              :model-value="quantities[d.id] ?? null"
              :min="0"
              :max="100000"
              :use-grouping="false"
              show-buttons
              button-layout="horizontal"
              increment-button-icon="pi pi-plus"
              decrement-button-icon="pi pi-minus"
              :input-class="'tabular w-12 text-center sm:w-16'"
              :aria-label="`Jumlah ${d.kind === 'NOTE' ? 'lembar' : 'keping'} ${formatNumber(d.value)}`"
              placeholder="0"
              @update:model-value="(v: number | null) => setQty(d.id, v)"
            />
            <span class="tabular ml-auto whitespace-nowrap text-right text-xs sm:text-sm" :class="subtotal(d) ? 'font-semibold' : 'text-ink-faint'">
              {{ formatRupiah(subtotal(d)) }}
            </span>
          </li>
        </ul>
      </fieldset>
    </div>

    <div class="mt-4 flex flex-wrap items-end justify-between gap-2 rounded-lg bg-jade-700 px-4 py-3 text-white">
      <div class="text-sm text-jade-100">{{ pieces }} lembar/keping</div>
      <div class="text-right">
        <div class="text-xs text-jade-100">Total dihitung</div>
        <output class="tabular block text-3xl font-bold tracking-tight" aria-live="polite">{{ formatRupiah(total) }}</output>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Label denominasi menyerupai tepi uang: garis aksen di kiri. */
.denom-note {
  @apply border-l-4 border-jade-500 bg-jade-50 text-jade-900;
}
.denom-coin {
  @apply border-l-4 border-amber-500 bg-amber-100 text-ink;
}
</style>
