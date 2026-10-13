import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import { api } from '@/services'
import type { Branding } from '@/types/api'
import { applyBrandColor } from '@/utils/brand'

/** Branding merchant (nama tampilan, logo, warna utama) — dimuat sekali setelah login. */
export const useBrandStore = defineStore('brand', () => {
  const branding = ref<Branding | null>(null)

  const name = computed(() => branding.value?.displayName || branding.value?.organizationName || 'CuanRena')
  const logo = computed(() => branding.value?.logo ?? null)

  function set(b: Branding | null) {
    branding.value = b
    applyBrandColor(b?.primaryColor ?? null)
  }

  async function load() {
    try {
      set((await api().get<Branding>('/api/branding')).data)
    } catch {
      // tampilan bawaan sudah memadai bila branding gagal dimuat
    }
  }

  function reset() {
    set(null)
  }

  return { branding, name, logo, load, set, reset }
})
