<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'
import { useSessionStore } from '@/stores/session'
import { useAttendanceStore } from '@/stores/attendance'
import { toCountLines, useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'
import { formatRupiah } from '@/utils/money'

/**
 * Figma "Beginning cash balance": satu kolom "Cash in the drawer". Server tetap menyimpan rincian
 * per pecahan, jadi nominal dipecah otomatis dari pecahan terbesar (modal awal tidak berubah nilainya).
 */
const session = useSessionStore()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const router = useRouter()
const { busy, run } = useApiAction()

const loading = ref(true)
const amount = ref<number | null>(null)

onMounted(async () => {
  try {
    await Promise.all([cashier.loadDenominations(), attendance.load(), cashier.load()])
  } finally {
    loading.value = false
  }
  if (!cashier.current && !(attendance.current?.status === 'WORKING')) await router.replace({ name: 'my-attendance' })
})

const att = computed(() => attendance.current)
const canOpen = computed(() => session.can('cashier.open'))

/** Pecah nominal menjadi jumlah per pecahan (greedy). null bila tidak bisa dipecah persis. */
function split(total: number) {
  const q: Record<string, number> = {}
  let rest = total
  for (const d of [...cashier.denominations].sort((x, y) => y.value - x.value)) {
    const n = Math.floor(rest / d.value)
    q[d.id] = n
    rest -= n * d.value
  }
  return rest === 0 ? q : null
}
const parts = computed(() => (amount.value === null ? null : split(Math.round(amount.value))))
const smallest = computed(() => Math.min(...cashier.denominations.map((d) => d.value)))

async function save() {
  const t = session.terminal
  if (!t || amount.value === null || !parts.value) return
  const opened = await run((key) => cashier.open(t.id, toCountLines(parts.value!), null, key), 'Beginning cash tersimpan, kasir dibuka')
  if (opened) await router.push({ name: 'pos' })
}
</script>

<template>
  <div class="mx-auto max-w-3xl">
    <h1 class="text-xl">Beginning cash balance</h1>

    <div v-if="loading" class="mt-10 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <template v-else>
      <Message v-if="!canOpen" severity="warn" class="mt-6" :closable="false">
        Role Anda tidak memiliki izin membuka kasir di outlet ini.
      </Message>

      <div v-else-if="cashier.current" class="mt-6 rounded-xl border border-line bg-field p-5">
        <p class="font-semibold">Kasir sudah dibuka di {{ cashier.current.terminalCode }}.</p>
        <p class="mt-1 text-sm text-ink-soft">Modal awal tidak bisa diubah setelah kasir dibuka.</p>
        <Button class="mt-4" label="Ke kasir" @click="router.push({ name: 'pos' })" />
      </div>

      <div v-else-if="att?.status !== 'WORKING'" class="mt-6 rounded-xl border border-amber-500 bg-amber-100 p-5">
        <p class="font-semibold">Clock in dulu sebelum mengisi saldo awal.</p>
        <Button class="mt-4" label="Ke Clock in" @click="router.push({ name: 'my-attendance' })" />
      </div>

      <form v-else class="mt-6 rounded-xl border border-line bg-field p-6" @submit.prevent="save">
        <label for="drawer" class="mb-1 block text-base">Cash in the drawer</label>
        <InputNumber v-model="amount" input-id="drawer" prefix="Rp " locale="id-ID" :min="0" :max-fraction-digits="0"
          class="w-full" input-class="w-full" placeholder="Rp" />
        <small v-if="amount !== null && !parts" class="mt-1 block text-alert-600">
          Nominal harus kelipatan {{ formatRupiah(smallest) }}.
        </small>
        <p class="mt-3 text-sm text-ink-soft">Modal awal tidak bisa diubah setelah disimpan.</p>
        <div class="mt-6 grid grid-cols-2 gap-3">
          <Button type="submit" label="Save" :loading="busy" :disabled="amount === null || !parts" />
          <Button type="button" label="Cancel" severity="danger" outlined @click="router.push({ name: 'pos' })" />
        </div>
      </form>
    </template>
  </div>
</template>
