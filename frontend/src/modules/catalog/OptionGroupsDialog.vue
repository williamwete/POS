<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import ToggleSwitch from 'primevue/toggleswitch'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import type { OptionGroupAdmin } from '@/types/api'
import { formatRupiah } from '@/utils/money'

/** Kelola grup opsi (mis. Level pedas, Topping) dan pilihannya. Produk memilih grup di form produk. */
const props = defineProps<{ visible: boolean }>()
const emit = defineEmits<{ (e: 'update:visible', v: boolean): void; (e: 'changed'): void }>()

const { busy, run } = useApiAction()
const groups = ref<OptionGroupAdmin[]>([])
const newGroup = ref({ name: '', minSelect: 0, maxSelect: 1 })
const newOption = ref<Record<string, { name: string; priceDelta: number }>>({})

async function load() {
  await run(async () => {
    groups.value = (await api().get<OptionGroupAdmin[]>('/api/catalog/option-groups')).data
  })
}
watch(() => props.visible, (v) => { if (v) void load() })

async function addGroup() {
  if (!newGroup.value.name.trim()) return
  const res = await run(() => api().post<OptionGroupAdmin[]>('/api/catalog/option-groups', { ...newGroup.value, name: newGroup.value.name.trim() }), 'Grup dibuat')
  if (res) {
    groups.value = res.data
    newGroup.value = { name: '', minSelect: 0, maxSelect: 1 }
    emit('changed')
  }
}

async function saveGroup(g: OptionGroupAdmin) {
  const res = await run(() => api().put<OptionGroupAdmin[]>(`/api/catalog/option-groups/${g.id}`, {
    name: g.name, minSelect: g.minSelect, maxSelect: g.maxSelect, sortOrder: g.sortOrder, active: g.active,
  }), 'Grup disimpan')
  if (res) { groups.value = res.data; emit('changed') }
}

async function addOption(g: OptionGroupAdmin) {
  const o = newOption.value[g.id]
  if (!o?.name.trim()) return
  const res = await run(() => api().post<OptionGroupAdmin[]>(`/api/catalog/option-groups/${g.id}/options`, { name: o.name.trim(), priceDelta: o.priceDelta ?? 0 }), 'Opsi ditambah')
  if (res) { groups.value = res.data; newOption.value[g.id] = { name: '', priceDelta: 0 }; emit('changed') }
}

async function toggleOption(g: OptionGroupAdmin, o: OptionGroupAdmin['options'][number]) {
  const res = await run(() => api().put<OptionGroupAdmin[]>(`/api/catalog/option-groups/${g.id}/options/${o.id}`, {
    name: o.name, priceDelta: o.priceDelta, sortOrder: o.sortOrder, active: !o.active,
  }))
  if (res) { groups.value = res.data; emit('changed') }
}
</script>

<template>
  <Dialog :visible="visible" modal header="Opsi produk" class="w-full max-w-2xl" @update:visible="(v: boolean) => emit('update:visible', v)">
    <p class="mb-4 text-sm text-ink-soft">Buat grup pilihan seperti “Level pedas” atau “Topping”, lalu pasang ke produk di form produk. Harga tambahan masuk ke harga baris saat dijual.</p>
    <div class="space-y-4">
      <section v-for="g in groups" :key="g.id" class="rounded-xl border border-line p-4">
        <div class="flex flex-wrap items-end gap-3">
          <div class="min-w-40 flex-1"><label class="mb-1 block text-xs font-medium">Nama grup</label><InputText v-model="g.name" class="w-full" maxlength="60" /></div>
          <div><label class="mb-1 block text-xs font-medium">Min pilih</label><InputNumber v-model="g.minSelect" :min="0" :max="20" show-buttons button-layout="horizontal" input-class="w-14 text-center" /></div>
          <div><label class="mb-1 block text-xs font-medium">Maks pilih</label><InputNumber v-model="g.maxSelect" :min="1" :max="20" show-buttons button-layout="horizontal" input-class="w-14 text-center" /></div>
          <div class="flex items-center gap-2 pb-2"><ToggleSwitch v-model="g.active" /><span class="text-sm">Aktif</span></div>
          <Button label="Simpan" size="small" :loading="busy" @click="saveGroup(g)" />
        </div>
        <ul class="mt-3 divide-y divide-line text-sm">
          <li v-for="o in g.options" :key="o.id" class="flex items-center justify-between py-1.5">
            <span :class="o.active ? '' : 'text-ink-faint line-through'">{{ o.name }}</span>
            <span class="flex items-center gap-3">
              <span class="tabular text-ink-soft">{{ Number(o.priceDelta) > 0 ? `+${formatRupiah(o.priceDelta)}` : 'gratis' }}</span>
              <ToggleSwitch :model-value="o.active" :aria-label="`Aktifkan ${o.name}`" @update:model-value="toggleOption(g, o)" />
            </span>
          </li>
        </ul>
        <form class="mt-3 flex flex-wrap items-end gap-2" @submit.prevent="addOption(g)">
          <InputText v-model="(newOption[g.id] ??= { name: '', priceDelta: 0 }).name" placeholder="Nama opsi, mis. Pedas" class="min-w-40 flex-1" maxlength="60" :aria-label="`Opsi baru ${g.name}`" />
          <div class="w-40 shrink-0"><InputNumber v-model="newOption[g.id]!.priceDelta" prefix="+Rp " :min="0" locale="id-ID" fluid :aria-label="`Harga tambahan ${g.name}`" /></div>
          <Button type="submit" label="Tambah opsi" size="small" severity="secondary" :loading="busy" />
        </form>
      </section>
      <p v-if="!groups.length" class="rounded-xl border border-dashed border-line p-6 text-center text-sm text-ink-soft">Belum ada grup opsi.</p>

      <form class="flex flex-wrap items-end gap-3 rounded-xl bg-field p-4" @submit.prevent="addGroup">
        <div class="min-w-40 flex-1"><label class="mb-1 block text-xs font-medium">Grup baru</label><InputText v-model="newGroup.name" placeholder="Level pedas" class="w-full" maxlength="60" /></div>
        <div><label class="mb-1 block text-xs font-medium">Min</label><InputNumber v-model="newGroup.minSelect" :min="0" :max="20" input-class="w-14 text-center" /></div>
        <div><label class="mb-1 block text-xs font-medium">Maks</label><InputNumber v-model="newGroup.maxSelect" :min="1" :max="20" input-class="w-14 text-center" /></div>
        <Button type="submit" label="Buat grup" icon="pi pi-plus" :loading="busy" />
      </form>
    </div>
  </Dialog>
</template>
