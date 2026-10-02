<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'
import { useSessionStore } from '@/stores/session'
import { api } from '@/services'
import { ApiError } from '@/services/apiClient'
import type { Terminal } from '@/types/api'
import { formatBusinessDate } from '@/utils/format'

const session = useSessionStore()
const router = useRouter()

const selectedOutlet = ref<string | null>(session.outletId ?? (session.outlets.length === 1 ? session.outlets[0]!.id : null))
const selectedTerminal = ref<string | null>(session.terminal?.id ?? null)
const terminals = ref<Terminal[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

const outlet = computed(() => session.outlets.find((o) => o.id === selectedOutlet.value) ?? null)
const terminal = computed(() => terminals.value.find((t) => t.id === selectedTerminal.value) ?? null)
const activeOutlets = computed(() => session.outlets.filter((o) => o.active))
const adminLanding = computed(() => {
  const order: [string, string, 'org' | 'any'][] = [
    ['users', 'user.manage', 'org'], ['outlets', 'outlet.manage', 'org'], ['terminals', 'terminal.manage', 'any'],
    ['employees', 'employee.view', 'any'], ['users', 'user.view', 'any'], ['audit', 'audit.view', 'any'],
  ]
  return order.find(([, p, s]) => session.can(p, s))?.[0] ?? null
})

async function loadTerminals() {
  terminals.value = []
  if (!selectedOutlet.value) return
  loading.value = true
  error.value = null
  try {
    const res = await api().get<Terminal[]>('/api/terminals', { query: { outletId: selectedOutlet.value } })
    terminals.value = res.data.filter((t) => t.active)
    if (!terminals.value.some((t) => t.id === selectedTerminal.value)) {
      selectedTerminal.value = terminals.value.length === 1 ? terminals.value[0]!.id : null
    }
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Gagal memuat terminal.'
  } finally {
    loading.value = false
  }
}

watch(selectedOutlet, loadTerminals)
onMounted(loadTerminals)

async function confirm() {
  if (!outlet.value || !terminal.value) return
  // Verifikasi ulang ke server: terminal masih aktif & dapat diakses.
  try {
    const res = await api().get<Terminal>(`/api/terminals/${terminal.value.id}`)
    if (!res.data.active) {
      error.value = 'Terminal ini sudah dinonaktifkan. Pilih terminal lain.'
      await loadTerminals()
      return
    }
    session.selectContext(outlet.value.id, { id: res.data.id, code: res.data.code, name: res.data.name })
    await router.push({ name: 'home' })
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Gagal memilih terminal.'
  }
}
</script>

<template>
  <div class="mx-auto max-w-4xl">
    <h1 class="text-2xl font-bold">Pilih tempat Anda bekerja</h1>
    <p class="mt-1 text-ink-soft">Semua transaksi akan tercatat di outlet dan terminal yang Anda pilih.</p>

    <Message v-if="error" severity="error" class="mt-4" :closable="false">{{ error }}</Message>

    <div v-if="activeOutlets.length === 0" class="mt-8 rounded-lg border border-line bg-surface p-6">
      <p class="font-semibold">Akun Anda belum memiliki akses ke outlet mana pun.</p>
      <p class="mt-1 text-sm text-ink-soft">Minta admin menambahkan akses outlet ke akun Anda.</p>
      <Button
        v-if="adminLanding"
        class="mt-4"
        label="Buka administrasi"
        severity="secondary"
        @click="router.push({ name: adminLanding })"
      />
    </div>

    <template v-else>
      <fieldset class="mt-8">
        <legend class="text-sm font-semibold text-ink-soft">Outlet</legend>
        <div class="mt-2 grid gap-3 sm:grid-cols-2">
          <label
            v-for="o in activeOutlets"
            :key="o.id"
            :class="[
              'flex cursor-pointer items-start gap-3 rounded-lg border bg-surface p-4',
              selectedOutlet === o.id ? 'border-jade-600 ring-2 ring-jade-100' : 'border-line hover:border-jade-500',
            ]"
          >
            <input v-model="selectedOutlet" type="radio" name="outlet" :value="o.id" class="mt-1 accent-jade-600" />
            <span>
              <span class="tabular block text-sm font-bold text-jade-700">{{ o.code }}</span>
              <span class="block font-semibold">{{ o.name }}</span>
              <span class="mt-1 block text-xs text-ink-soft">Business date {{ formatBusinessDate(o.businessDate) }}</span>
            </span>
          </label>
        </div>
      </fieldset>

      <fieldset v-if="outlet" class="mt-8">
        <legend class="text-sm font-semibold text-ink-soft">Terminal di {{ outlet.name }}</legend>
        <div v-if="loading" class="mt-4 flex justify-center"><ProgressSpinner style="width: 2rem; height: 2rem" /></div>
        <p v-else-if="terminals.length === 0" class="mt-2 rounded-lg border border-dashed border-line p-4 text-sm text-ink-soft">
          Belum ada terminal aktif di outlet ini. Admin dapat menambahkannya di menu Terminal & device.
        </p>
        <div v-else class="mt-2 grid gap-3 sm:grid-cols-3">
          <label
            v-for="t in terminals"
            :key="t.id"
            :class="[
              'relative cursor-pointer overflow-hidden rounded-lg border-2 bg-surface p-4 pt-6',
              selectedTerminal === t.id ? 'border-amber-500' : 'border-line hover:border-amber-500/60',
            ]"
          >
            <!-- tepi atas bergerigi seperti struk -->
            <span aria-hidden="true" class="ticket-edge absolute inset-x-0 top-0 h-2" />
            <input v-model="selectedTerminal" type="radio" name="terminal" :value="t.id" class="sr-only" />
            <span class="tabular block text-xl font-bold tracking-tight">{{ t.code }}</span>
            <span class="block text-sm text-ink-soft">{{ t.name }}</span>
            <span class="mt-3 block text-xs text-ink-faint">
              <i class="pi pi-print mr-1" />{{ t.printerName ?? 'Tanpa printer' }}
            </span>
            <i v-if="selectedTerminal === t.id" class="pi pi-check-circle absolute right-3 top-5 text-lg text-amber-700" />
          </label>
        </div>
      </fieldset>

      <div class="mt-8 flex flex-wrap items-center gap-3">
        <Button
          :label="terminal ? `Mulai di ${terminal.code}` : 'Pilih terminal'"
          icon="pi pi-check"
          :disabled="!terminal"
          @click="confirm"
        />
        <Button
          v-if="adminLanding"
          label="Lanjut ke administrasi tanpa terminal"
          severity="secondary"
          text
          @click="router.push({ name: adminLanding })"
        />
      </div>
    </template>
  </div>
</template>

<style scoped>
.ticket-edge {
  background: radial-gradient(circle at 6px -2px, transparent 5px, #e8a33d 5.5px) 0 0 / 12px 8px repeat-x;
}
</style>
