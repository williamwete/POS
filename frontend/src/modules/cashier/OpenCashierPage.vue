<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Textarea from 'primevue/textarea'
import ProgressSpinner from 'primevue/progressspinner'
import { useConfirm } from 'primevue/useconfirm'
import { useSessionStore } from '@/stores/session'
import { useAttendanceStore } from '@/stores/attendance'
import { toCountLines, useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'
import { countTotal, formatRupiah } from '@/utils/money'
import DenominationCounter from './DenominationCounter.vue'

const session = useSessionStore()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const router = useRouter()
const confirm = useConfirm()
const { busy, run } = useApiAction()

const loading = ref(true)
const quantities = ref<Record<string, number | null>>({})
const note = ref('')

onMounted(async () => {
  try {
    await Promise.all([cashier.loadDenominations(), attendance.load(), cashier.load()])
  } finally {
    loading.value = false
  }
})

const values = computed(() => new Map(cashier.denominations.map((d) => [d.id, d.value])))
const total = computed(() => countTotal(values.value, quantities.value))
const att = computed(() => attendance.current)
const attendanceReady = computed(
  () => att.value?.status === 'WORKING' && att.value.outletId === session.outletId,
)
const canOpen = computed(() => session.can('cashier.open'))

async function clockIn() {
  if (session.outletId) await run((key) => attendance.clockIn(session.outletId!, key), 'Clock in tercatat')
}

function submit() {
  const t = session.terminal
  if (!t) return
  confirm.require({
    header: `Buka kasir di ${t.code}?`,
    message:
      total.value === 0
        ? 'Modal awal Rp 0. Pastikan laci kas memang kosong. Modal awal tidak bisa diubah setelah kasir dibuka.'
        : `Modal awal ${formatRupiah(total.value)}. Modal awal tidak bisa diubah setelah kasir dibuka.`,
    acceptLabel: 'Buka kasir',
    rejectLabel: 'Hitung ulang',
    accept: async () => {
      const opened = await run(
        (key) => cashier.open(t.id, toCountLines(quantities.value), note.value.trim() || null, key),
        'Kasir dibuka',
      )
      if (opened) await router.push({ name: 'home' })
    },
  })
}
</script>

<template>
  <div class="mx-auto max-w-4xl">
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 class="text-2xl font-bold">Buka kasir</h1>
        <p class="mt-1 text-ink-soft">Hitung uang di laci kas per pecahan. Jumlah ini menjadi modal awal shift Anda.</p>
      </div>
      <div v-if="session.terminal" class="rounded-md bg-amber-500 px-3 py-1 text-jade-900">
        <div class="text-xs font-medium">Terminal</div>
        <div class="tabular text-lg font-bold">{{ session.terminal.code }}</div>
      </div>
    </div>

    <div v-if="loading" class="mt-10 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <template v-else>
      <Message v-if="!canOpen" severity="warn" class="mt-6" :closable="false">
        Role Anda tidak memiliki izin membuka kasir di outlet ini.
      </Message>

      <div v-else-if="cashier.current" class="mt-6 rounded-2xl border border-line bg-surface p-5">
        <p class="font-semibold">Anda sudah membuka kasir di {{ cashier.current.terminalCode }}.</p>
        <p class="mt-1 text-sm text-ink-soft">Satu karyawan hanya boleh memegang satu laci kas pada satu waktu.</p>
        <Button class="mt-4" label="Kembali ke beranda" severity="secondary" @click="router.push({ name: 'home' })" />
      </div>

      <div v-else-if="!attendanceReady" class="mt-6 rounded-lg border border-amber-500 bg-amber-100 p-5">
        <p class="font-semibold">
          <template v-if="!att">Clock in dulu sebelum membuka kasir.</template>
          <template v-else-if="att.status === 'ON_BREAK'">Selesaikan istirahat dulu sebelum membuka kasir.</template>
          <template v-else>Anda clock in di outlet {{ att.outletCode }}. Kasir hanya bisa dibuka di outlet tempat Anda clock in.</template>
        </p>
        <Button v-if="!att" class="mt-4" label="Clock in sekarang" icon="pi pi-sign-in" :loading="busy" @click="clockIn" />
      </div>

      <form v-else class="mt-6 space-y-6" @submit.prevent="submit">
        <DenominationCounter v-model="quantities" :denominations="cashier.denominations" id-prefix="open" />
        <div>
          <label for="open-note" class="mb-1 block text-sm font-medium">Catatan (opsional)</label>
          <Textarea id="open-note" v-model="note" rows="2" maxlength="500" class="w-full" placeholder="Mis. modal dari brankas shift pagi" />
        </div>
        <div class="flex flex-wrap justify-end gap-2">
          <Button label="Batal" severity="secondary" text type="button" @click="router.push({ name: 'home' })" />
          <Button :label="`Buka kasir · ${formatRupiah(total)}`" icon="pi pi-lock-open" type="submit" :loading="busy" />
        </div>
      </form>
    </template>
  </div>
</template>
