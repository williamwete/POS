<script setup lang="ts">
defineProps<{ active: boolean }>()
</script>

<template>
  <span
    :class="[
      'inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium',
      active ? 'bg-jade-50 text-jade-700' : 'bg-field text-ink-soft',
    ]"
  >
    <span :class="['h-1.5 w-1.5 rounded-full', active ? 'bg-jade-500' : 'bg-ink-faint']" aria-hidden="true" />
    {{ active ? 'Aktif' : 'Nonaktif' }}
  </span>
</template>
