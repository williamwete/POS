<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ToggleSwitch from 'primevue/toggleswitch'
import Button from 'primevue/button'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useMenuStore } from '@/stores/menu'
import { useSessionStore } from '@/stores/session'
import type { MenuMatrixCell } from '@/types/api'

/**
 * Aktif/nonaktif menu per peran (Owner & Admin). Tampilan saja: izin API tetap dari permission.
 * Penyimpangan dari default ditandai; "Reset" mengembalikan ke default.
 */
const { busy, run } = useApiAction()
const menus = useMenuStore()
const session = useSessionStore()
const cells = ref<MenuMatrixCell[]>([])
const loading = ref(true)

const ROLE_LABEL: Record<string, string> = { ADMIN: 'Admin', OWNER: 'Owner', SUPERVISOR: 'Supervisor', CASHIER: 'Kasir' }
const roles = computed(() => ['OWNER', 'ADMIN', 'SUPERVISOR', 'CASHIER'].filter((r) => cells.value.some((c) => c.roleCode === r)))
const rows = computed(() => {
  const byMenu = new Map<string, { code: string; label: string; cells: Map<string, MenuMatrixCell> }>()
  for (const c of [...cells.value].sort((a, b) => a.sortOrder - b.sortOrder)) {
    const row = byMenu.get(c.menuCode) ?? { code: c.menuCode, label: c.label, cells: new Map() }
    row.cells.set(c.roleCode, c)
    byMenu.set(c.menuCode, row)
  }
  return [...byMenu.values()]
})
const customized = computed(() => cells.value.filter((c) => c.enabled !== c.defaultEnabled).length)

async function load() {
  await run(async () => {
    cells.value = (await api().get<MenuMatrixCell[]>('/api/admin/menus')).data
  })
  loading.value = false
}
onMounted(load)

async function set(c: MenuMatrixCell, enabled: boolean | null) {
  const res = await run(async () => (await api().put<MenuMatrixCell[]>('/api/admin/menus',
    { menuCode: c.menuCode, roleCode: c.roleCode, enabled })).data)
  if (res) {
    cells.value = res
    void menus.load(session.outletId)   // menu saya sendiri bisa ikut berubah
  }
}

async function resetAll() {
  for (const c of cells.value.filter((x) => x.enabled !== x.defaultEnabled)) await set(c, null)
}
</script>

<template>
  <div class="mx-auto max-w-5xl">
    <PageHeader title="Akses menu" description="Pilih menu yang tampil untuk tiap peran. Default sudah disiapkan; hanya perubahan dari default yang disimpan. Menu tidak memberi izin tambahan: hak akses tetap mengikuti peran.">
      <template #actions>
        <Button label="Kembalikan semua ke default" icon="pi pi-undo" severity="secondary" outlined :disabled="busy || !customized" @click="resetAll" />
      </template>
    </PageHeader>

    <p v-if="loading" class="text-sm text-ink-soft">Memuat…</p>
    <div v-else class="overflow-x-auto rounded-xl border border-line bg-surface">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-line bg-jade-50 text-left">
            <th class="px-4 py-3 font-semibold">Menu</th>
            <th v-for="r in roles" :key="r" class="px-4 py-3 text-center font-semibold">{{ ROLE_LABEL[r] ?? r }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="row in rows" :key="row.code" class="border-b border-line last:border-0">
            <th scope="row" class="px-4 py-3 text-left font-medium">{{ row.label }}</th>
            <td v-for="r in roles" :key="r" class="px-4 py-3 text-center">
              <template v-if="row.cells.get(r)">
                <ToggleSwitch :model-value="row.cells.get(r)!.enabled" :disabled="busy"
                  :aria-label="`${row.label} untuk ${ROLE_LABEL[r] ?? r}`" @update:model-value="(v: boolean) => set(row.cells.get(r)!, v)" />
                <div class="mt-1 h-4 text-[11px]">
                  <button v-if="row.cells.get(r)!.enabled !== row.cells.get(r)!.defaultEnabled" type="button"
                    class="text-jade-700 underline" :disabled="busy" @click="set(row.cells.get(r)!, null)">diubah · reset</button>
                  <span v-else class="text-ink-faint">default</span>
                </div>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
