<script setup lang="ts">
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import type { Sale } from '@/types/api'
import { formatRupiah } from '@/utils/money'

defineProps<{ visible: boolean; sales: Sale[]; busy?: boolean; canResume: boolean }>()
const emit = defineEmits<{ (e: 'update:visible', v: boolean): void; (e: 'resume', id: string): void }>()
const time = new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' })
</script>

<template>
  <Dialog :visible="visible" modal header="Transaksi ditahan" class="w-full max-w-lg" @update:visible="(v) => emit('update:visible', v)">
    <p v-if="!canResume" class="mb-3 rounded-md bg-amber-100 p-3 text-sm">
      Tahan atau selesaikan transaksi yang sedang berjalan sebelum melanjutkan transaksi lain.
    </p>
    <p v-if="sales.length === 0" class="text-sm text-ink-soft">Tidak ada transaksi yang ditahan.</p>
    <ul v-else class="divide-y divide-line rounded-lg border border-line">
      <li v-for="s in sales" :key="s.id" class="flex items-center justify-between gap-3 p-3">
        <div>
          <div class="tabular font-semibold">{{ formatRupiah(s.grandTotal) }}</div>
          <div class="text-xs text-ink-soft">
            {{ s.lineCount }} baris · ditahan {{ s.heldAt ? time.format(new Date(s.heldAt)) : '' }}
          </div>
        </div>
        <Button label="Lanjutkan" size="small" :disabled="!canResume" :loading="busy" @click="emit('resume', s.id)" />
      </li>
    </ul>
  </Dialog>
</template>
