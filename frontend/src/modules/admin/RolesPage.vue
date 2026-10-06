<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import Message from 'primevue/message'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Permission, Role } from '@/types/api'

const session = useSessionStore()
const { busy, run } = useApiAction()

const roles = ref<Role[]>([])
const permissions = ref<Permission[]>([])
const selectedId = ref<string | null>(null)
const draft = ref<string[]>([])

const canManageRoles = computed(() => session.can('role.manage', 'org'))
const myMaxRank = computed(() => {
  const orgWide = (session.me?.roles ?? []).filter((r) => !r.outletId)
  return Math.max(0, ...orgWide.map((r) => roles.value.find((x) => x.id === r.roleId)?.rank ?? 0))
})
const myPermissions = computed(() => new Set(session.me?.organizationPermissions ?? []))
const selected = computed(() => roles.value.find((r) => r.id === selectedId.value) ?? null)
const editable = computed(() => canManageRoles.value && !!selected.value && selected.value.rank < myMaxRank.value)
const dirty = computed(() => {
  const a = [...draft.value].sort().join()
  const b = [...(selected.value?.permissions ?? [])].sort().join()
  return a !== b
})

const modules = computed(() => {
  const groups = new Map<string, Permission[]>()
  for (const p of permissions.value) {
    groups.set(p.module, [...(groups.get(p.module) ?? []), p])
  }
  return [...groups.entries()]
})

async function load() {
  await run(async () => {
    const [r, p] = await Promise.all([api().get<Role[]>('/api/roles'), api().get<Permission[]>('/api/permissions')])
    roles.value = r.data
    permissions.value = p.data
    if (!selectedId.value) selectedId.value = r.data[0]?.id ?? null
  })
}
onMounted(load)
watch(selected, (r) => (draft.value = [...(r?.permissions ?? [])]), { immediate: true })

async function save() {
  if (!selected.value) return
  const res = await run(
    () => api().put<Role>(`/api/roles/${selected.value!.id}/permissions`, { permissionCodes: draft.value }),
    'Permission role disimpan',
  )
  if (res) {
    roles.value = roles.value.map((r) => (r.id === res.data.id ? res.data : r))
    await session.refresh()
  }
}
</script>

<template>
  <div>
    <PageHeader
      title="Role & permission"
      description="Role menentukan apa yang boleh dilakukan. Tingkat role mencegah user memberi akses melebihi miliknya."
    />

    <div class="grid gap-6 lg:grid-cols-[16rem_minmax(0,1fr)]">
      <nav aria-label="Daftar role">
        <ul class="space-y-1">
          <li v-for="r in roles" :key="r.id">
            <button
              type="button"
              :class="[
                'flex w-full items-center justify-between rounded-md px-3 py-2 text-left text-sm',
                r.id === selectedId ? 'bg-jade-50 font-semibold text-jade-700' : 'hover:bg-surface',
              ]"
              :aria-current="r.id === selectedId"
              @click="selectedId = r.id"
            >
              <span>{{ r.name }}</span>
              <span class="tabular text-xs text-ink-faint" :title="`Tingkat ${r.rank}`">{{ r.rank }}</span>
            </button>
          </li>
        </ul>
      </nav>

      <section v-if="selected" class="rounded-2xl border border-line bg-surface p-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="text-lg font-semibold">{{ selected.name }}</h2>
            <p class="text-sm text-ink-soft">{{ selected.description }} Tingkat {{ selected.rank }}, {{ selected.permissions.length }} permission.</p>
          </div>
          <Button v-if="editable" label="Simpan permission" :disabled="!dirty" :loading="busy" @click="save" />
        </div>

        <Message v-if="canManageRoles && !editable" severity="secondary" class="mt-4" :closable="false">
          Role ini setara atau di atas role Anda dan hanya dapat dilihat.
        </Message>

        <div class="mt-6 grid gap-6 sm:grid-cols-2 xl:grid-cols-3">
          <fieldset v-for="[module, perms] in modules" :key="module">
            <legend class="mb-2 text-sm font-semibold capitalize">{{ module }}</legend>
            <ul class="space-y-2">
              <li v-for="p in perms" :key="p.code" class="flex items-start gap-2">
                <Checkbox
                  v-model="draft"
                  :value="p.code"
                  :input-id="`perm-${p.code}`"
                  :disabled="!editable || !myPermissions.has(p.code)"
                />
                <label :for="`perm-${p.code}`" class="text-sm leading-tight">
                  {{ p.description }}
                  <span class="tabular block text-xs text-ink-faint">{{ p.code }}</span>
                </label>
              </li>
            </ul>
          </fieldset>
        </div>
      </section>
    </div>
  </div>
</template>
