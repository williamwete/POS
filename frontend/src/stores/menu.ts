import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/services'
import type { MenuItem } from '@/types/api'

/**
 * Menu samping untuk user + outlet saat ini. Hanya tampilan: izin API tetap permission + RLS.
 * Gagal memuat = daftar kosong (layout jatuh ke menu minimal), bukan memblokir aplikasi.
 */
export const useMenuStore = defineStore('menu', () => {
  const items = ref<MenuItem[]>([])
  const loaded = ref(false)
  const codes = computed(() => new Set(items.value.map((m) => m.code)))

  async function load(outletId: string | null) {
    try {
      items.value = (await api().get<MenuItem[]>('/api/menus/me', { query: { outletId: outletId ?? undefined } })).data
    } catch {
      items.value = []
    }
    loaded.value = true
  }

  function has(code: string) {
    return codes.value.has(code)
  }

  function reset() {
    items.value = []
    loaded.value = false
  }

  return { items, loaded, load, has, reset }
})
