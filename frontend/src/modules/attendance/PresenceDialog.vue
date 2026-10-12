<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'

/**
 * Figma "Clock in/Clock out": ambil foto + PIN pribadi sebagai bukti kasir yang menjaga adalah orangnya.
 * Foto diperkecil (maks 480 px, JPEG) di perangkat sebelum dikirim. PIN tidak disimpan di client.
 */
const props = defineProps<{ visible: boolean; mode: 'in' | 'out'; busy: boolean; error: string | null; photoRequired: boolean }>()
const emit = defineEmits<{ 'update:visible': [v: boolean]; confirm: [proof: { pin: string; photo: string }] }>()

const video = ref<HTMLVideoElement | null>(null)
const stream = ref<MediaStream | null>(null)
const photo = ref<string | null>(null)
const pin = ref('')
const cameraError = ref<string | null>(null)

const ready = computed(() => /^\d{6}$/.test(pin.value) && (!props.photoRequired || !!photo.value))

async function startCamera() {
  cameraError.value = null
  try {
    stream.value = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: 640, height: 480 }, audio: false })
    await nextTick()
    if (video.value) {
      video.value.srcObject = stream.value
      await video.value.play().catch(() => undefined)
    }
  } catch {
    cameraError.value = 'Kamera tidak dapat dibuka. Izinkan akses kamera di browser, lalu coba lagi.'
  }
}

function stopCamera() {
  stream.value?.getTracks().forEach((t) => t.stop())
  stream.value = null
}

function capture() {
  const v = video.value
  if (!v || !v.videoWidth) return
  const scale = Math.min(1, 480 / v.videoWidth)
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(v.videoWidth * scale)
  canvas.height = Math.round(v.videoHeight * scale)
  canvas.getContext('2d')!.drawImage(v, 0, 0, canvas.width, canvas.height)
  photo.value = canvas.toDataURL('image/jpeg', 0.7)
  stopCamera()
}

function retake() {
  photo.value = null
  void startCamera()
}

watch(() => props.visible, (v) => {
  if (v) {
    pin.value = ''
    photo.value = null
    if (props.photoRequired) void startCamera()
  } else {
    stopCamera()
  }
})
onBeforeUnmount(stopCamera)

function submit() {
  if (!ready.value) return
  emit('confirm', { pin: pin.value, photo: photo.value ?? '' })
}
</script>

<template>
  <Dialog :visible="visible" modal :draggable="false" :header="mode === 'in' ? 'Clock in' : 'Clock out'" class="w-full max-w-md"
    @update:visible="(v: boolean) => emit('update:visible', v)">
    <form class="space-y-4" @submit.prevent="submit">
      <div v-if="photoRequired">
        <p class="mb-1 text-sm">Take a photo</p>
        <div class="grid aspect-[4/3] place-items-center overflow-hidden rounded-xl border border-line bg-field">
          <img v-if="photo" :src="photo" alt="Foto verifikasi" class="h-full w-full object-cover" />
          <video v-else ref="video" class="h-full w-full -scale-x-100 object-cover" playsinline muted />
        </div>
        <Message v-if="cameraError" severity="warn" :closable="false" class="mt-2">{{ cameraError }}</Message>
        <div class="mt-2 flex justify-center">
          <Button v-if="!photo" type="button" icon="pi pi-camera" label="Ambil foto" severity="secondary" :disabled="!stream" @click="capture" />
          <Button v-else type="button" icon="pi pi-refresh" label="Ulangi" severity="secondary" text @click="retake" />
        </div>
      </div>

      <div>
        <label for="presence-pin" class="mb-1 block text-sm">Pin</label>
        <InputText id="presence-pin" v-model="pin" type="password" inputmode="numeric" maxlength="6" autocomplete="off"
          class="tabular w-full text-center text-xl tracking-[0.5em]" placeholder="••••••" aria-describedby="pin-help" />
        <small id="pin-help" class="text-ink-faint">PIN pribadi 6 digit. Hanya Anda yang tahu.</small>
      </div>

      <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

      <div class="grid gap-3">
        <Button type="submit" :label="mode === 'in' ? 'Clock in' : 'Clock out'" :disabled="!ready" :loading="busy" />
        <Button type="button" label="Cancel" severity="danger" outlined :disabled="busy" @click="emit('update:visible', false)" />
      </div>
    </form>
  </Dialog>
</template>
