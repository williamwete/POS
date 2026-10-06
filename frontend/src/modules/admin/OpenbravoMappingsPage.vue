<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import PageHeader from '@/components/PageHeader.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { MappingEntityType, OpenbravoMapping } from '@/types/api'
import { formatDateTime } from '@/utils/format'

/**
 * Pemetaan ID Openbravo (§39): ID tidak pernah di-hard-code; dokumen yang memakai entitas tanpa pemetaan
 * ditahan di antrean sync (Perlu ditinjau) sampai pemetaan diisi.
 */
const { busy, run } = useApiAction()
const rows = ref<OpenbravoMapping[]>([])
const drafts = ref<Record<string, string>>({})
const filter = ref<'ALL' | 'MISSING'>('ALL')

const GROUPS: { type: MappingEntityType; label: string; hint: string }[] = [
  { type: 'ORGANIZATION', label: 'Organisasi', hint: 'ID organisasi (AD_Org induk / client) di Openbravo' },
  { type: 'OUTLET', label: 'Outlet', hint: 'Organisasi toko (AD_Org) per outlet' },
  { type: 'WAREHOUSE', label: 'Gudang', hint: 'M_Warehouse sumber stok outlet' },
  { type: 'TERMINAL', label: 'Terminal', hint: 'Terminal / dokumen POS di Openbravo' },
  { type: 'PAYMENT_METHOD', label: 'Metode pembayaran', hint: 'FIN_PaymentMethod / akun keuangan' },
  { type: 'TAX', label: 'Pajak', hint: 'C_Tax / kategori pajak' },
]

const key = (r: OpenbravoMapping) => `${r.entityType}:${r.posId}`
async function load() {
  const res = await run(async () => (await api().get<OpenbravoMapping[]>('/api/admin/openbravo-mappings')).data)
  if (res) {
    rows.value = res
    drafts.value = Object.fromEntries(res.map((r) => [key(r), r.openbravoId ?? '']))
  }
}
onMounted(load)

const missing = computed(() => rows.value.filter((r) => !r.openbravoId).length)
const visible = (type: MappingEntityType) =>
  rows.value.filter((r) => r.entityType === type && (filter.value === 'ALL' || !r.openbravoId))
const changed = (r: OpenbravoMapping) => (drafts.value[key(r)] ?? '').trim() !== (r.openbravoId ?? '')
const valid = (v: string) => /^[A-Za-z0-9._:-]{1,64}$/.test(v.trim())

async function save(r: OpenbravoMapping) {
  const v = (drafts.value[key(r)] ?? '').trim()
  if (!valid(v)) return
  const res = await run(async () => (await api().put<OpenbravoMapping[]>('/api/admin/openbravo-mappings',
    { entityType: r.entityType, posId: r.posId, openbravoId: v })).data, 'Pemetaan disimpan')
  if (res) {
    rows.value = res
    drafts.value = Object.fromEntries(res.map((x) => [key(x), x.openbravoId ?? '']))
  }
}
</script>

<template>
  <div>
    <PageHeader title="Pemetaan Openbravo"
      description="Hubungkan data POS dengan ID di Openbravo. Dokumen hanya dikirim bila semua pemetaannya lengkap.">
      <template #actions>
        <Button :label="filter === 'ALL' ? `Tampilkan yang kosong (${missing})` : 'Tampilkan semua'" severity="secondary" text
          @click="filter = filter === 'ALL' ? 'MISSING' : 'ALL'" />
      </template>
    </PageHeader>

    <section v-for="g in GROUPS" :key="g.type" class="mb-4 rounded-2xl border border-line bg-surface p-5">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="font-semibold">{{ g.label }}</h2>
        <span class="text-xs text-ink-soft">{{ g.hint }}</span>
      </div>
      <ul class="mt-3 divide-y divide-line">
        <li v-for="r in visible(g.type)" :key="key(r)" class="flex flex-wrap items-center gap-3 py-2">
          <div class="min-w-48 flex-1">
            <div class="font-medium">{{ r.posName }}</div>
            <div class="tabular text-xs text-ink-soft">
              {{ r.posCode }}<template v-if="r.updatedAt"> · diubah {{ formatDateTime(r.updatedAt) }}<template v-if="r.updatedByName"> oleh {{ r.updatedByName }}</template></template>
            </div>
          </div>
          <form class="flex items-center gap-2" @submit.prevent="save(r)">
            <InputText v-model="drafts[key(r)]" :aria-label="`ID Openbravo ${r.posName}`" placeholder="ID Openbravo"
              :invalid="!!drafts[key(r)] && !valid(drafts[key(r)]!)" class="tabular w-64" maxlength="64" />
            <Button type="submit" label="Simpan" size="small" :loading="busy"
              :disabled="!changed(r) || !valid(drafts[key(r)] ?? '')" />
          </form>
          <span v-if="!r.openbravoId" class="rounded-full bg-alert-50 px-2 py-0.5 text-xs font-medium text-alert-600">Belum dipetakan</span>
        </li>
        <li v-if="!visible(g.type).length" class="py-2 text-sm text-ink-soft">Semua sudah dipetakan.</li>
      </ul>
    </section>
  </div>
</template>
