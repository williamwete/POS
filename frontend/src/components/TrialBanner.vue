<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { api } from '@/services'
import { useSessionStore } from '@/stores/session'
import type { Subscription } from '@/types/api'

/** Pemberitahuan masa percobaan: tampil hanya untuk merchant dengan paket TRIAL. */
const session = useSessionStore()
const sub = ref<Subscription | null>(null)

onMounted(async () => {
  if (!session.isAuthenticated) return
  try {
    sub.value = (await api().get<Subscription | null>('/api/subscription')).data ?? null
  } catch {
    sub.value = null
  }
})

const days = computed(() => {
  const end = sub.value?.trialEndsAt
  return end ? Math.ceil((new Date(end).getTime() - Date.now()) / 86_400_000) : null
})
const show = computed(() => sub.value?.status === 'TRIAL' && (sub.value.expired || (days.value !== null && days.value <= 7)))
</script>

<template>
  <div v-if="show" :class="['mb-4 rounded-lg border p-3 text-sm', sub?.expired ? 'border-alert-600 bg-alert-100 text-alert-600' : 'border-amber-500 bg-amber-100']" role="status">
    <template v-if="sub?.expired">
      <strong>Masa percobaan berakhir.</strong> Penjualan baru dan pembukaan kasir dinonaktifkan. Data Anda aman; hubungi penyedia layanan untuk berlangganan.
    </template>
    <template v-else>
      Masa percobaan berakhir dalam <strong>{{ days }} hari</strong>. Hubungi penyedia layanan untuk berlangganan agar penjualan tidak terhenti.
    </template>
  </div>
</template>
