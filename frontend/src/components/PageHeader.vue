<script setup lang="ts">
defineProps<{ title: string; description?: string }>()
</script>

<template>
  <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
    <div class="min-w-0">
      <h1 class="text-2xl font-bold">{{ title }}</h1>
      <p v-if="description" class="mt-1 max-w-2xl text-sm text-ink-soft">{{ description }}</p>
    </div>
    <div class="flex flex-wrap gap-2"><slot name="actions" /></div>
  </div>
</template>
