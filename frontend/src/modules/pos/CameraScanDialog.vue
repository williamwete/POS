<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue'
import Dialog from 'primevue/dialog'

/** Pindai barcode dengan kamera (laptop/HP). Dimuat malas agar tidak membebani layar kasir. */
const visible = defineModel<boolean>('visible', { required: true })
const emit = defineEmits<{ scan: [code: string] }>()

const video = ref<HTMLVideoElement | null>(null)
const error = ref('')
let stop: (() => void) | null = null
let done = false

async function start() {
  error.value = ''
  done = false
  if (!navigator.mediaDevices?.getUserMedia) {
    error.value = 'Kamera tidak tersedia di perangkat/browser ini (butuh HTTPS atau localhost).'
    return
  }
  try {
    const { BrowserMultiFormatReader } = await import('@zxing/browser')
    await nextTick()
    if (!video.value) return
    const reader = new BrowserMultiFormatReader()
    const controls = await reader.decodeFromVideoDevice(undefined, video.value, (result) => {
      if (result && !done) {
        done = true
        emit('scan', result.getText())
        visible.value = false
      }
    })
    stop = () => controls.stop()
  } catch {
    error.value = 'Kamera tidak bisa dibuka. Izinkan akses kamera di browser, lalu coba lagi.'
  }
}

function halt() {
  stop?.()
  stop = null
}

watch(visible, (v) => (v ? void start() : halt()))
onBeforeUnmount(halt)
</script>

<template>
  <Dialog v-model:visible="visible" header="Pindai barcode" modal class="w-full max-w-md">
    <p v-if="error" class="text-sm text-alert-600" role="alert">{{ error }}</p>
    <template v-else>
      <video ref="video" class="aspect-video w-full rounded-lg bg-black object-cover" muted playsinline />
      <p class="mt-2 text-sm text-ink-soft">Arahkan barcode ke kamera. Kode terbaca otomatis.</p>
    </template>
  </Dialog>
</template>
