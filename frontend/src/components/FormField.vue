<script setup lang="ts">
defineProps<{ label: string; for?: string; error?: string; hint?: string; required?: boolean }>()
</script>

<template>
  <div>
    <label :for="$props.for" class="mb-1 block text-sm font-medium">
      {{ label }}<span v-if="required" class="text-alert-600" aria-hidden="true"> *</span>
    </label>
    <slot />
    <small v-if="error" class="mt-1 block text-alert-600" role="alert">{{ error }}</small>
    <small v-else-if="hint" class="mt-1 block text-ink-faint">{{ hint }}</small>
  </div>
</template>
