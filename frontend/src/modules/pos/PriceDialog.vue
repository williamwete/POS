<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import InputText from 'primevue/inputtext'
import type { SaleItem } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/** Ubah harga baris (§18). Selalu beralasan; persetujuan diminta server sesuai setting. */
const props = defineProps<{ visible: boolean; item: SaleItem | null; busy?: boolean }>()
const emit = defineEmits<{
  (e: 'update:visible', v: boolean): void
  (e: 'confirm', d: { price: number; reason: string }): void
}>()
const price = ref<number | null>(null)
const reason = ref('')
watch(() => props.visible, (v) => {
  if (v && props.item) {
    price.value = props.item.unitPrice
    reason.value = props.item.priceOverrideReason ?? ''
  }
})
</script>

<template>
  <Dialog :visible="visible" modal :header="`Ubah harga · ${item?.productName ?? ''}`" class="w-full max-w-md"
    @update:visible="(v) => emit('update:visible', v)">
    <form v-if="item" class="space-y-4"
      @submit.prevent="price !== null && reason.trim().length >= 3 && emit('confirm', { price, reason: reason.trim() })">
      <p class="text-sm text-ink-soft">Harga price list: <span class="tabular font-semibold text-ink">{{ formatRupiah(item.listPrice) }}</span>.
        Mengembalikan ke harga ini tidak memerlukan persetujuan.</p>
      <div>
        <label for="new-price" class="mb-1 block text-sm font-medium">Harga satuan baru</label>
        <InputNumber v-model="price" input-id="new-price" class="w-full" :min="0" :max-fraction-digits="0" prefix="Rp " locale="id-ID" />
      </div>
      <div>
        <label for="price-reason" class="mb-1 block text-sm font-medium">Alasan</label>
        <InputText id="price-reason" v-model="reason" class="w-full" maxlength="200" placeholder="Mis. kemasan penyok" />
      </div>
      <div class="flex justify-end gap-2">
        <Button label="Batal" text severity="secondary" type="button" @click="emit('update:visible', false)" />
        <Button label="Simpan harga" type="submit" :loading="busy" :disabled="price === null || reason.trim().length < 3" />
      </div>
    </form>
  </Dialog>
</template>
