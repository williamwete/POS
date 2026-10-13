<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import type { Product, ProductOptionGroup } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/** Pilihan opsi produk (mis. level pedas, topping) sebelum masuk keranjang. Harga akhir dihitung server. */
const props = defineProps<{ visible: boolean; product: Product | null; busy?: boolean }>()
const emit = defineEmits<{
  (e: 'update:visible', v: boolean): void
  (e: 'confirm', optionIds: string[]): void
}>()

const picked = ref<Record<string, string[]>>({})
const groups = computed<ProductOptionGroup[]>(() => props.product?.optionGroups ?? [])

watch(() => props.visible, (v) => {
  if (!v) return
  // grup wajib dengan satu pilihan: pilih opsi pertama sebagai awal agar kasir tinggal mengganti
  picked.value = Object.fromEntries(groups.value.map((g) => [g.id, g.minSelect === 1 && g.maxSelect === 1 && g.options[0] ? [g.options[0].id] : []]))
})

function toggle(g: ProductOptionGroup, id: string) {
  const cur = picked.value[g.id] ?? []
  if (g.maxSelect === 1) {
    picked.value[g.id] = cur[0] === id && g.minSelect === 0 ? [] : [id]
    return
  }
  if (cur.includes(id)) picked.value[g.id] = cur.filter((x) => x !== id)
  else if (cur.length < g.maxSelect) picked.value[g.id] = [...cur, id]
}

const chosen = computed(() => Object.values(picked.value).flat())
const delta = computed(() => groups.value.flatMap((g) => g.options).filter((o) => chosen.value.includes(o.id)).reduce((s, o) => s + Number(o.priceDelta), 0))
const total = computed(() => (props.product?.price ?? 0) + delta.value)
const problem = computed(() => {
  for (const g of groups.value) {
    const n = (picked.value[g.id] ?? []).length
    if (n < g.minSelect) return `Pilih ${g.name}`
    if (n > g.maxSelect) return `${g.name}: maksimal ${g.maxSelect}`
  }
  return ''
})
</script>

<template>
  <Dialog :visible="visible" modal :header="product?.name ?? 'Pilihan'" class="w-full max-w-md" @update:visible="(v: boolean) => emit('update:visible', v)">
    <form class="space-y-5" @submit.prevent="!problem && emit('confirm', chosen)">
      <fieldset v-for="g in groups" :key="g.id">
        <legend class="mb-2 text-sm font-semibold">
          {{ g.name }}
          <span class="ml-1 text-xs font-normal text-ink-faint">
            {{ g.minSelect >= 1 ? 'wajib' : 'opsional' }}<template v-if="g.maxSelect > 1"> · maks {{ g.maxSelect }}</template>
          </span>
        </legend>
        <div class="flex flex-wrap gap-2">
          <button v-for="o in g.options" :key="o.id" type="button" :aria-pressed="(picked[g.id] ?? []).includes(o.id)"
            :class="['rounded-lg border px-4 py-2 text-sm transition', (picked[g.id] ?? []).includes(o.id) ? 'border-jade-600 bg-jade-50 font-semibold text-jade-700' : 'border-line bg-white hover:bg-field']"
            @click="toggle(g, o.id)">
            {{ o.name }}<span v-if="Number(o.priceDelta) > 0" class="tabular ml-1 text-xs text-ink-soft">+{{ formatRupiah(o.priceDelta) }}</span>
          </button>
        </div>
      </fieldset>
      <p v-if="problem" class="text-sm text-alert-600" role="alert">{{ problem }}</p>
      <div class="flex items-center justify-between border-t border-line pt-4">
        <span class="tabular text-lg font-bold">{{ formatRupiah(total) }}</span>
        <div class="flex gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="emit('update:visible', false)" />
          <Button label="Tambah" type="submit" :disabled="!!problem" :loading="busy" />
        </div>
      </div>
    </form>
  </Dialog>
</template>
