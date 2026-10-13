<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { IMPORT_TEMPLATE, parseCsv, toImportRows, validateRows, type ImportRow } from '@/utils/csv'

const visible = defineModel<boolean>('visible', { required: true })
const props = defineProps<{ outletId: string | null; outletName: string }>()
const emit = defineEmits<{ imported: [] }>()

const { busy, run } = useApiAction()
const fileName = ref('')
const rows = ref<ImportRow[]>([])
const problems = ref<string[]>([])
const error = ref('')

watch(visible, (v) => {
  if (v) { fileName.value = ''; rows.value = []; problems.value = []; error.value = '' }
})

const preview = computed(() => rows.value.slice(0, 6))
const canImport = computed(() => rows.value.length > 0 && problems.value.length === 0)

async function pick(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  error.value = ''
  fileName.value = file.name
  if (file.size > 2_000_000) { error.value = 'Berkas terlalu besar (maks 2 MB)'; rows.value = []; return }
  const { rows: parsed, missing } = toImportRows(parseCsv(await file.text()))
  if (missing.length) { error.value = `Kolom wajib tidak ditemukan: ${missing.join(', ')}`; rows.value = []; problems.value = []; return }
  if (parsed.length > 500) { error.value = 'Maksimal 500 baris per berkas; pecah berkas Anda.'; rows.value = []; return }
  rows.value = parsed
  problems.value = validateRows(parsed)
}

function downloadTemplate() {
  const url = URL.createObjectURL(new Blob([IMPORT_TEMPLATE], { type: 'text/csv' }))
  const a = document.createElement('a')
  a.href = url
  a.download = 'template-produk.csv'
  a.click()
  URL.revokeObjectURL(url)
}

async function submit() {
  const res = await run(async () => (await api().post<{ created: number; updated: number; categoriesCreated: number }>(
    '/api/catalog/products/import', { rows: rows.value, outletId: props.outletId })).data)
  if (res) {
    visible.value = false
    emit('imported')
  }
}
</script>

<template>
  <Dialog v-model:visible="visible" header="Impor produk dari CSV" modal class="w-full max-w-3xl">
    <div class="space-y-4 text-sm">
      <p class="text-ink-soft">
        Kolom: <strong>sku, nama, harga</strong> (wajib), kategori, satuan, barcode, stok. SKU yang sudah ada diperbarui; kategori baru dibuat otomatis.
        Stok diisi untuk <strong>{{ outletName || 'outlet terpilih' }}</strong>. Semua baris dibatalkan bila ada yang salah.
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <label class="cursor-pointer rounded-lg bg-jade-500 px-4 py-2 font-medium text-white">
          Pilih berkas CSV
          <input type="file" accept=".csv,text/csv,text/plain" class="sr-only" @change="pick" />
        </label>
        <button type="button" class="text-jade-700 underline" @click="downloadTemplate">Unduh template</button>
        <span v-if="fileName" class="text-ink-soft">{{ fileName }} · {{ rows.length }} baris</span>
      </div>

      <p v-if="error" class="text-alert-600" role="alert">{{ error }}</p>
      <ul v-if="problems.length" class="list-disc pl-5 text-alert-600" role="alert">
        <li v-for="p in problems.slice(0, 8)" :key="p">{{ p }}</li>
        <li v-if="problems.length > 8">…dan {{ problems.length - 8 }} galat lain</li>
      </ul>

      <div v-if="preview.length" class="overflow-x-auto rounded-lg border border-line">
        <table class="w-full text-left text-xs">
          <thead class="bg-field"><tr><th class="p-2">SKU</th><th class="p-2">Nama</th><th class="p-2">Kategori</th><th class="p-2">Harga</th><th class="p-2">Barcode</th><th class="p-2">Stok</th></tr></thead>
          <tbody>
            <tr v-for="r in preview" :key="r.sku + r.name" class="border-t border-line">
              <td class="p-2">{{ r.sku }}</td><td class="p-2">{{ r.name }}</td><td class="p-2">{{ r.category || '—' }}</td>
              <td class="p-2">{{ r.price || '—' }}</td><td class="p-2">{{ r.barcode || '—' }}</td><td class="p-2">{{ r.stock || '—' }}</td>
            </tr>
          </tbody>
        </table>
        <p v-if="rows.length > preview.length" class="p-2 text-xs text-ink-faint">…dan {{ rows.length - preview.length }} baris lain</p>
      </div>

      <div class="flex justify-end gap-2 pt-2">
        <Button label="Batal" severity="secondary" text type="button" @click="visible = false" />
        <Button :label="`Impor ${rows.length || ''} produk`" :disabled="!canImport" :loading="busy" @click="submit" />
      </div>
    </div>
  </Dialog>
</template>
