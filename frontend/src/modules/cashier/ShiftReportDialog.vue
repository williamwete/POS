<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import ProgressSpinner from 'primevue/progressspinner'
import type { ShiftReport } from '@/types/api'
import { useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'
import ShiftReportPaper from './ShiftReportPaper.vue'

/**
 * Pratinjau & cetak X report (dibuat saat dibuka, kasir tetap buka) atau Z report (cash-up yang tersimpan
 * saat tutup kasir). Setiap X report dan setiap cetak Z tercatat di audit.
 */
const props = defineProps<{ sessionId: string | null; type: 'X' | 'Z' }>()
const visible = defineModel<boolean>('visible', { required: true })
const cashier = useCashierStore()
const { busy, run } = useApiAction()
const report = ref<ShiftReport | null>(null)

watch([visible, () => props.sessionId, () => props.type], async () => {
  report.value = null
  if (!visible.value || !props.sessionId) return
  const id = props.sessionId
  report.value = await run(() => (props.type === 'X' ? cashier.xReport(id) : cashier.zReport(id)))
  if (!report.value) visible.value = false
}, { immediate: true })

async function print() {
  if (!props.sessionId || !report.value) return
  if (props.type === 'Z') {
    const ok = await run(() => cashier.recordZPrint(props.sessionId!))
    if (ok === null) return
  }
  await nextTick()
  window.print()
}
</script>

<template>
  <Dialog v-model:visible="visible" modal :header="type === 'Z' ? 'Z report' : 'X report'" class="w-full max-w-md">
    <div v-if="!report" class="flex justify-center p-6"><ProgressSpinner style="width: 2rem; height: 2rem" /></div>
    <template v-else>
      <p v-if="type === 'X'" class="mb-3 text-sm text-ink-soft">Laporan sementara. Kasir tetap buka; angka bisa berubah.</p>
      <div class="receipt-print max-h-[60vh] overflow-auto rounded border border-line bg-field p-2">
        <ShiftReportPaper :report="report" />
      </div>
      <div class="mt-4 flex justify-end gap-2">
        <Button label="Tutup" text severity="secondary" @click="visible = false" />
        <Button label="Cetak" icon="pi pi-print" :loading="busy" @click="print" />
      </div>
    </template>
  </Dialog>
</template>
