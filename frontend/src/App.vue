<script setup lang="ts">
import { watch } from 'vue'
import Toast from 'primevue/toast'
import ConfirmDialog from 'primevue/confirmdialog'
import { useSessionStore } from '@/stores/session'
import { useBrandStore } from '@/stores/brand'

// Branding merchant mengikuti sesi: dimuat saat masuk, dibersihkan saat keluar.
const session = useSessionStore()
const brand = useBrandStore()
watch(() => session.isAuthenticated, (on) => (on ? void brand.load() : brand.reset()), { immediate: true })
</script>

<template>
  <Toast position="top-right" />
  <ConfirmDialog />
  <RouterView />
</template>
