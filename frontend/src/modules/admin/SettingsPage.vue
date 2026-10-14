<script setup lang="ts">
import { onMounted, ref } from 'vue'
import ToggleSwitch from 'primevue/toggleswitch'
import Button from 'primevue/button'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useAttendanceStore } from '@/stores/attendance'

const attendance = useAttendanceStore()
const { busy, run } = useApiAction()
const required = ref(true)
const loading = ref(true)
const offlineAllow = ref(false)
const offlineMax = ref<number | null>(0)
const offlineMinutes = ref<number | null>(0)

onMounted(async () => {
  await run(async () => {
    const s = (await api().get<Record<string, unknown>>('/api/settings/effective')).data
    required.value = s.attendance_required !== false
    offlineAllow.value = s.allow_offline_sale === true
    offlineMax.value = Number(s.max_offline_sale_amount ?? 0)
    offlineMinutes.value = Number(s.max_offline_duration_minutes ?? 0)
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

async function saveOffline() {
  await run(async () => {
    await api().put('/api/settings/offline', {
      allow: offlineAllow.value, maxAmount: Math.max(0, Math.floor(offlineMax.value ?? 0)),
      maxMinutes: Math.max(0, Math.floor(offlineMinutes.value ?? 0)),
    })
    return true
  }, 'Pengaturan offline disimpan')
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

    <section class="mt-4 rounded-xl border border-line bg-field p-5">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-base font-semibold">Penjualan offline (tunai)</h2>
          <p class="mt-1 text-sm text-ink-soft">
            Saat internet atau server mati, kasir tetap bisa menjual secara tunai dan transaksi dikirim otomatis begitu
            koneksi kembali. Transaksi offline selalu diterima karena barang sudah keluar; yang melanggar aturan di bawah
            ditandai agar Anda tinjau di Dashboard &rarr; Transaksi offline.
          </p>
        </div>
        <ToggleSwitch v-model="offlineAllow" :disabled="loading || busy" input-id="off-allow" aria-label="Izinkan penjualan offline" />
      </div>
      <div class="mt-4 grid gap-4 sm:grid-cols-2">
        <div class="flex flex-col gap-1">
          <label for="off-max" class="text-sm font-semibold">Batas nilai per transaksi (Rp)</label>
          <input id="off-max" v-model.number="offlineMax" type="number" min="0" max="100000000" step="1000" class="p-inputtext p-component" />
          <span class="text-xs text-ink-faint">0 = tanpa batas</span>
        </div>
        <div class="flex flex-col gap-1">
          <label for="off-min" class="text-sm font-semibold">Batas keterlambatan kirim (menit)</label>
          <input id="off-min" v-model.number="offlineMinutes" type="number" min="0" max="10080" step="10" class="p-inputtext p-component" />
          <span class="text-xs text-ink-faint">0 = tanpa batas</span>
        </div>
      </div>
      <Button class="mt-4" label="Simpan pengaturan offline" :disabled="loading || busy" @click="saveOffline" />
    </section>
  </div>
</template>
