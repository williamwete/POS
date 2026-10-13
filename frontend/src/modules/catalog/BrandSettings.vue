<script setup lang="ts">
import { computed, reactive, watch } from 'vue'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import FormField from '@/components/FormField.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useBrandStore } from '@/stores/brand'
import { useToast } from 'primevue/usetoast'
import type { Branding } from '@/types/api'
import { DEFAULT_BRAND, fileToLogo, isHexColor, isReadableBrand, buildPalette } from '@/utils/brand'

/** Merek merchant: nama tampilan, warna utama, dan logo. Berlaku di header, menu, dan struk. */
const brand = useBrandStore()
const toast = useToast()
const { busy, run } = useApiAction()
const form = reactive({ displayName: '', color: '', logo: '' as string })

watch(() => brand.branding, (b) => {
  form.displayName = b?.displayName ?? ''
  form.color = b?.primaryColor ?? ''
  form.logo = b?.logo ?? ''
}, { immediate: true })

const colorValid = computed(() => !form.color || isReadableBrand(form.color))
const colorHint = computed(() => {
  if (!form.color) return 'Kosong = biru bawaan'
  if (!isHexColor(form.color)) return 'Format #RRGGBB, mis. #0F7A6B'
  return isReadableBrand(form.color) ? 'Warna dipakai untuk tombol dan sorotan' : 'Terlalu terang: teks putih di tombol tidak terbaca'
})
const swatches = computed(() => {
  const p = buildPalette(isReadableBrand(form.color) ? form.color : DEFAULT_BRAND)
  return [100, 500, 600, 700, 900].map((s) => p[s]!)
})

async function pick(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0]
  if (!file) return
  try {
    form.logo = await fileToLogo(file)
  } catch (err) {
    toast.add({ severity: 'warn', summary: err instanceof Error ? err.message : 'Logo gagal dibaca', life: 4000 })
  }
  ;(e.target as HTMLInputElement).value = ''
}

async function save() {
  if (!colorValid.value) return
  const res = await run(() => api().put<Branding>('/api/branding', { displayName: form.displayName.trim() || null, primaryColor: form.color || null, logo: form.logo || null }), 'Merek disimpan')
  if (res) brand.set(res.data)
}
</script>

<template>
  <section class="mb-8 max-w-2xl rounded-2xl border border-line bg-surface p-5" aria-labelledby="brand-title">
    <h2 id="brand-title" class="text-lg font-semibold">Merek &amp; tampilan</h2>
    <p class="mb-4 text-sm text-ink-soft">Nama, logo, dan warna utama bisnis Anda, tampil di aplikasi dan struk untuk semua outlet.</p>
    <form class="grid gap-4 sm:grid-cols-2" @submit.prevent="save">
      <FormField label="Nama tampilan" for="b-name" class="sm:col-span-2" hint="Kosong = nama organisasi">
        <InputText id="b-name" v-model="form.displayName" class="w-full" maxlength="60" :placeholder="brand.branding?.organizationName" />
      </FormField>
      <FormField label="Warna utama" for="b-color" :hint="colorHint">
        <div class="flex items-center gap-2">
          <input type="color" :value="isHexColor(form.color) ? form.color : DEFAULT_BRAND" class="h-10 w-12 cursor-pointer rounded-lg border border-line bg-white p-1" aria-label="Pilih warna"
            @input="form.color = ($event.target as HTMLInputElement).value.toUpperCase()" />
          <InputText id="b-color" v-model="form.color" class="w-32 font-mono" maxlength="7" placeholder="#0F7A6B" :invalid="!colorValid" />
          <span class="flex overflow-hidden rounded-md" aria-hidden="true"><span v-for="c in swatches" :key="c" class="h-6 w-5" :style="{ background: c }" /></span>
        </div>
      </FormField>
      <FormField label="Logo" for="b-logo" hint="PNG/JPEG/WebP; otomatis dikecilkan">
        <div class="flex items-center gap-3">
          <img v-if="form.logo" :src="form.logo" alt="Logo saat ini" class="h-12 w-12 rounded-lg border border-line object-contain" />
          <label class="cursor-pointer rounded-lg border border-line px-3 py-2 text-sm font-medium hover:bg-field" for="b-logo">{{ form.logo ? 'Ganti' : 'Unggah logo' }}</label>
          <input id="b-logo" type="file" accept="image/png,image/jpeg,image/webp" class="sr-only" @change="pick" />
          <Button v-if="form.logo" type="button" label="Hapus" text severity="secondary" size="small" @click="form.logo = ''" />
        </div>
      </FormField>
      <div class="flex justify-end sm:col-span-2"><Button label="Simpan merek" type="submit" :loading="busy" :disabled="!colorValid" /></div>
    </form>
  </section>
</template>
