<script setup lang="ts">
import { computed } from 'vue'
import Select from 'primevue/select'
import Button from 'primevue/button'
import type { Role } from '@/types/api'

export interface GrantDraft {
  roleId: string | null
  outletId: string | null
}

const props = defineProps<{
  modelValue: GrantDraft[]
  roles: Role[]
  /** outlet yang boleh dijadikan scope (akses outlet user) */
  outlets: { id: string; code: string; name: string }[]
  /** rank maksimum (eksklusif) yang boleh diberikan pengelola */
  maxRank: number
  disabled?: boolean
}>()
const emit = defineEmits<{ 'update:modelValue': [GrantDraft[]] }>()

const roleOptions = computed(() =>
  props.roles.map((r) => ({ label: r.name, value: r.id, disabled: r.rank >= props.maxRank })),
)
const scopeOptions = computed(() => [
  { label: 'Semua outlet (organisasi)', value: null as string | null },
  ...props.outlets.map((o) => ({ label: `${o.code} ${o.name}`, value: o.id as string | null })),
])

function update(i: number, patch: Partial<GrantDraft>) {
  const next = props.modelValue.map((g, idx) => (idx === i ? { ...g, ...patch } : g))
  emit('update:modelValue', next)
}
function add() {
  emit('update:modelValue', [...props.modelValue, { roleId: null, outletId: props.outlets[0]?.id ?? null }])
}
function remove(i: number) {
  emit('update:modelValue', props.modelValue.filter((_, idx) => idx !== i))
}
function locked(g: GrantDraft) {
  const r = props.roles.find((x) => x.id === g.roleId)
  return !!r && r.rank >= props.maxRank
}
</script>

<template>
  <div>
    <p v-if="!modelValue.length" class="rounded-md border border-dashed border-line p-3 text-sm text-ink-soft">
      Belum ada role. User tanpa role tidak dapat melakukan apa pun.
    </p>
    <ul class="space-y-2">
      <li v-for="(g, i) in modelValue" :key="i" class="flex flex-wrap items-center gap-2">
        <Select
          :model-value="g.roleId"
          :options="roleOptions"
          option-label="label"
          option-value="value"
          option-disabled="disabled"
          placeholder="Pilih role"
          class="min-w-44 flex-1"
          :disabled="disabled || locked(g)"
          :aria-label="`Role baris ${i + 1}`"
          @update:model-value="update(i, { roleId: $event })"
        />
        <Select
          :model-value="g.outletId"
          :options="scopeOptions"
          option-label="label"
          option-value="value"
          placeholder="Semua outlet (organisasi)"
          class="min-w-52 flex-1"
          :disabled="disabled || locked(g)"
          :aria-label="`Berlaku di, baris ${i + 1}`"
          @update:model-value="update(i, { outletId: $event })"
        />
        <Button
          icon="pi pi-times"
          text
          rounded
          severity="secondary"
          :disabled="disabled || locked(g)"
          :aria-label="`Hapus role baris ${i + 1}`"
          @click="remove(i)"
        />
      </li>
    </ul>
    <Button v-if="!disabled" class="mt-2" label="Tambah role" icon="pi pi-plus" text size="small" @click="add" />
    <p class="mt-1 text-xs text-ink-faint">
      Role dengan tingkat setara atau di atas role Anda tidak dapat diberikan atau dicabut.
    </p>
  </div>
</template>
