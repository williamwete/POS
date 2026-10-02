<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import InputText from 'primevue/inputtext'
import SelectButton from 'primevue/selectbutton'
import { formatRupiah } from '@/utils/money'

/**
 * Diskon baris atau transaksi (§20). Pratinjau nominal hanya perkiraan; server menghitung nilai
 * pasti dan meminta persetujuan bila melebihi batas kasir.
 */
const props = defineProps<{ visible: boolean; title: string; base: number; busy?: boolean }>()
const emit = defineEmits<{
  (e: 'update:visible', v: boolean): void
  (e: 'confirm', d: { type: 'PERCENTAGE' | 'AMOUNT'; value: number; reason: string }): void
}>()

const type = ref<'PERCENTAGE' | 'AMOUNT'>('PERCENTAGE')
const value = ref<number | null>(null)
const reason = ref('')
const TYPES = [{ label: 'Persen', value: 'PERCENTAGE' }, { label: 'Rupiah', value: 'AMOUNT' }]
const PRESETS = ['Promo member', 'Barang display', 'Kemasan rusak', 'Kompensasi pelanggan']

watch(() => props.visible, (v) => {
  if (v) {
    type.value = 'PERCENTAGE'
    value.value = null
    reason.value = ''
  }
})

const preview = computed(() => {
  if (!value.value || value.value <= 0) return 0
  return type.value === 'PERCENTAGE' ? Math.round((props.base * value.value) / 100) : Math.min(value.value, props.base)
})
const valid = computed(() =>
  !!value.value && value.value > 0 && (type.value === 'AMOUNT' || value.value <= 100) && reason.value.trim().length >= 3,
)
</script>

<template>
  <Dialog :visible="visible" modal :header="title" class="w-full max-w-md" @update:visible="(v) => emit('update:visible', v)">
    <form class="space-y-4" @submit.prevent="valid && emit('confirm', { type, value: value!, reason: reason.trim() })">
      <SelectButton v-model="type" :options="TYPES" option-label="label" option-value="value" :allow-empty="false" aria-label="Jenis diskon" />
      <div>
        <label for="disc-value" class="mb-1 block text-sm font-medium">{{ type === 'PERCENTAGE' ? 'Persen' : 'Nominal (Rp)' }}</label>
        <InputNumber
          v-model="value"
          input-id="disc-value"
          class="w-full"
          :min="0"
          :max="type === 'PERCENTAGE' ? 100 : undefined"
          :max-fraction-digits="type === 'PERCENTAGE' ? 2 : 0"
          :suffix="type === 'PERCENTAGE' ? ' %' : undefined"
          :prefix="type === 'AMOUNT' ? 'Rp ' : undefined"
          locale="id-ID"
        />
        <p class="mt-1 text-sm text-ink-soft">
          Dari {{ formatRupiah(base) }} → potongan sekitar <span class="tabular font-semibold text-ink">{{ formatRupiah(preview) }}</span>
        </p>
      </div>
      <div>
        <label for="disc-reason" class="mb-1 block text-sm font-medium">Alasan</label>
        <div class="mb-2 flex flex-wrap gap-2">
          <button
            v-for="p in PRESETS"
            :key="p"
            type="button"
            :class="['rounded-full border px-3 py-1 text-xs', reason === p ? 'border-jade-600 bg-jade-50 text-jade-700' : 'border-line']"
            @click="reason = p"
          >
            {{ p }}
          </button>
        </div>
        <InputText id="disc-reason" v-model="reason" class="w-full" maxlength="200" />
      </div>
      <div class="flex justify-end gap-2">
        <Button label="Batal" text severity="secondary" type="button" @click="emit('update:visible', false)" />
        <Button label="Terapkan diskon" type="submit" :disabled="!valid" :loading="busy" />
      </div>
    </form>
  </Dialog>
</template>
