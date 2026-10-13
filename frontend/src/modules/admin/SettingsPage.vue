<script setup lang="ts">
import { onMounted, ref } from 'vue'
import ToggleSwitch from 'primevue/toggleswitch'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useAttendanceStore } from '@/stores/attendance'

const attendance = useAttendanceStore()
const { busy, run } = useApiAction()
const required = ref(true)
const loading = ref(true)

onMounted(async () => {
  await run(async () => {
    const s = (await api().get<Record<string, unknown>>('/api/settings/effective')).data
    required.value = s.attendance_required !== false
  })
  loading.value = false
})

async function toggle(value: boolean) {
  const prev = required.value
  required.value = value
  const ok = await run(async () => {
    await api().put('/api/settings/attendance-required', { required: value })
    return true
  }, 'Pengaturan disimpan')
  if (!ok) required.value = prev
  else attendance.required = value
}
</script>

<template>
  <div class="mx-auto max-w-3xl">
    <h1 class="text-xl">Pengaturan</h1>
    <p class="mt-1 text-sm text-ink-soft">Pengaturan ini berlaku untuk seluruh outlet merchant Anda.</p>

    <section class="mt-6 rounded-xl border border-line bg-field p-5">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-base font-semibold">Wajib clock in sebelum membuka kasir</h2>
          <p class="mt-1 text-sm text-ink-soft">
            Aktif: kasir harus clock in (absen) dulu. Nonaktif: kasir langsung membuka kasir tanpa clock in; jam kerjanya tetap
            tercatat otomatis dari buka sampai tutup kasir. Cocok untuk usaha kecil yang tidak memakai absensi.
          </p>
        </div>
        <ToggleSwitch :model-value="required" :disabled="loading || busy" input-id="att-required" aria-label="Wajib clock in"
          @update:model-value="toggle" />
      </div>
    </section>
  </div>
</template>
