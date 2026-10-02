<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import Textarea from 'primevue/textarea'

/** Dialog alasan wajib (void barang / void transaksi) dengan pilihan cepat. */
const props = defineProps<{
  visible: boolean
  title: string
  description?: string
  presets: string[]
  minLength: number
  confirmLabel: string
  busy?: boolean
}>()
const emit = defineEmits<{ (e: 'update:visible', v: boolean): void; (e: 'confirm', reason: string): void }>()
const reason = ref('')
watch(() => props.visible, (v) => v && (reason.value = ''))
</script>

<template>
  <Dialog :visible="visible" modal :header="title" class="w-full max-w-md" @update:visible="(v) => emit('update:visible', v)">
    <form class="space-y-4" @submit.prevent="reason.trim().length >= minLength && emit('confirm', reason.trim())">
      <p v-if="description" class="text-sm text-ink-soft">{{ description }}</p>
      <div class="flex flex-wrap gap-2">
        <button
          v-for="p in presets"
          :key="p"
          type="button"
          :class="['rounded-full border px-3 py-1 text-sm', reason === p ? 'border-jade-600 bg-jade-50 text-jade-700' : 'border-line hover:border-jade-500']"
          @click="reason = p"
        >
          {{ p }}
        </button>
      </div>
      <div>
        <label for="reason-text" class="mb-1 block text-sm font-medium">Alasan</label>
        <Textarea id="reason-text" v-model="reason" rows="2" maxlength="200" class="w-full" />
        <p class="mt-1 text-xs text-ink-faint">Minimal {{ minLength }} karakter. Tercatat di audit log.</p>
      </div>
      <div class="flex justify-end gap-2">
        <Button label="Kembali" text severity="secondary" type="button" @click="emit('update:visible', false)" />
        <Button :label="confirmLabel" severity="danger" type="submit" :loading="busy" :disabled="reason.trim().length < minLength" />
      </div>
    </form>
  </Dialog>
</template>
