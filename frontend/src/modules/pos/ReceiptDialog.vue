<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import type { Receipt } from '@/types/api'
import { useSaleStore } from '@/stores/sale'
import { useApiAction } from '@/composables/useApiAction'
import ReceiptPaper from './ReceiptPaper.vue'

/** Pratinjau & cetak struk. Setiap cetak dicatat; cetak ulang tidak membuat transaksi baru (§30). */
const props = defineProps<{ visible: boolean; saleId: string | null }>()
const emit = defineEmits<{ (e: 'update:visible', v: boolean): void }>()
const sales = useSaleStore()
const { busy, run } = useApiAction()
const receipt = ref<Receipt | null>(null)

watch(() => [props.visible, props.saleId], async () => {
  receipt.value = null
  if (props.visible && props.saleId) {
    receipt.value = await run(() => sales.receipt(props.saleId!))
  }
})

async function print() {
  if (!props.saleId) return
  const res = await run((key) => sales.recordPrint(props.saleId!, key))
  if (!res) return
  receipt.value = await run(() => sales.receipt(props.saleId!))
  await nextTick()
  window.print()
}
</script>

<template>
  <Dialog :visible="visible" modal header="Struk" class="w-full max-w-md" @update:visible="(v) => emit('update:visible', v)">
    <div v-if="!receipt" class="flex justify-center p-6"><ProgressSpinner style="width: 2rem; height: 2rem" /></div>
    <template v-else>
      <div class="receipt-print max-h-[60vh] overflow-auto rounded border border-line bg-field p-2">
        <ReceiptPaper :receipt="receipt" />
      </div>
      <div class="mt-4 flex items-center justify-between gap-2">
        <span class="text-xs text-ink-faint">Dicetak {{ receipt.printCount }}×</span>
        <div class="flex gap-2">
          <Button label="Tutup" text severity="secondary" @click="emit('update:visible', false)" />
          <Button :label="receipt.printCount > 0 ? 'Cetak ulang' : 'Cetak'" icon="pi pi-print" :loading="busy" @click="print" />
        </div>
      </div>
    </template>
  </Dialog>
</template>
