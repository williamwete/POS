<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import Textarea from 'primevue/textarea'
import { useSessionStore } from '@/stores/session'
import { useAttendanceStore, formatDuration } from '@/stores/attendance'
import { toCountLines, useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'
import { formatRupiah } from '@/utils/money'
import DenominationCounter from './DenominationCounter.vue'

const session = useSessionStore()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const router = useRouter()
const { busy, run } = useApiAction()

const now = ref(new Date())
let timer: number | undefined
onMounted(() => {
  timer = window.setInterval(() => (now.value = new Date()), 15_000)
  if (!cashier.loaded) void run(() => cashier.load())
})
onBeforeUnmount(() => window.clearInterval(timer))

const s = computed(() => cashier.current)
const hasEmployee = computed(() => !!session.me?.employee)
const canOpen = computed(() => session.can('cashier.open'))
const otherTerminal = computed(() => !!s.value && !!session.terminal && s.value.terminalId !== session.terminal.id)
const timeFmt = new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' })
const since = computed(() => (s.value ? timeFmt.format(new Date(s.value.openedAt)) : ''))
const duration = computed(() =>
  s.value ? formatDuration(Math.max(0, Math.floor((now.value.getTime() - new Date(s.value.openedAt).getTime()) / 1000))) : '',
)

function useSessionTerminal() {
  const x = s.value
  if (!x) return
  session.selectContext(x.outletId, { id: x.terminalId, code: x.terminalCode, name: x.terminalName })
}

// ---- hitung kas tengah shift
const countOpen = ref(false)
const quantities = ref<Record<string, number | null>>({})
const countNote = ref('')
const lastCount = ref<number | null>(null)

async function openCount() {
  await run(() => cashier.loadDenominations())
  quantities.value = {}
  countNote.value = ''
  countOpen.value = true
}

async function submitCount() {
  const res = await run(
    (key) => cashier.cashCount(toCountLines(quantities.value), countNote.value.trim() || null, key),
    'Hitungan kas tercatat',
  )
  if (res) {
    lastCount.value = res.totalAmount
    countOpen.value = false
  }
}

// ---- batal buka kasir
const cancelOpen = ref(false)
const cancelReason = ref('')
async function submitCancel() {
  const ok = await run((key) => cashier.cancel(cancelReason.value.trim(), key), 'Buka kasir dibatalkan')
  if (ok !== null) {
    cancelOpen.value = false
    cancelReason.value = ''
  }
}
</script>

<template>
  <section v-if="hasEmployee" class="rounded-2xl border border-line bg-surface p-5" aria-labelledby="cashier-title">
    <div class="flex flex-wrap items-start justify-between gap-4">
      <div class="min-w-0">
        <h2 id="cashier-title" class="text-lg font-semibold">Kasir</h2>
        <p v-if="!s" class="text-sm text-ink-soft">Kasir belum dibuka.</p>
        <p v-else class="text-sm text-ink-soft">
          Buka di <span class="tabular font-semibold text-ink">{{ s.terminalCode }}</span> sejak
          <span class="tabular font-semibold text-ink">{{ since }}</span> ({{ duration }}).
          Modal awal <span class="tabular font-semibold text-ink">{{ formatRupiah(s.openingCash) }}</span>.
        </p>
        <p v-if="lastCount !== null && s" class="mt-1 text-sm text-jade-700">
          Hitungan terakhir {{ formatRupiah(lastCount) }} tercatat. Selisih diperiksa supervisor.
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <Button
          v-if="!s"
          label="Buka kasir"
          icon="pi pi-lock-open"
          :disabled="!canOpen || !session.terminal"
          @click="router.push({ name: 'cashier-open' })"
        />
        <template v-else-if="s.status === 'OPEN' && !otherTerminal">
          <Button v-if="session.can('sale.create')" label="Mulai transaksi" icon="pi pi-shopping-cart" @click="router.push({ name: 'pos' })" />
          <Button label="Hitung kas" icon="pi pi-calculator" severity="secondary" :loading="busy" @click="openCount" />
          <Button
            label="Kunci terminal"
            icon="pi pi-lock"
            severity="contrast"
            outlined
            :loading="busy"
            @click="run((key) => cashier.lock('MANUAL', key))"
          />
        </template>
      </div>
    </div>

    <div v-if="otherTerminal" class="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-md bg-amber-100 p-3 text-sm">
      <span>
        Session kasir Anda terbuka di <strong class="tabular">{{ s?.terminalCode }}</strong>, bukan di
        <span class="tabular">{{ session.terminal?.code }}</span>. Transaksi hanya bisa dilakukan di terminal session.
      </span>
      <Button :label="`Pindah ke ${s?.terminalCode}`" size="small" @click="useSessionTerminal" />
    </div>

    <p v-if="!s && canOpen && attendance.current?.status !== 'WORKING'" class="mt-3 text-xs text-ink-faint">
      Clock in terlebih dahulu sebelum membuka kasir.
    </p>
    <p v-if="!s && !canOpen" class="mt-3 text-xs text-ink-faint">Role Anda tidak memiliki izin membuka kasir di outlet ini.</p>
    <button
      v-if="s && s.status === 'OPEN'"
      type="button"
      class="mt-4 text-xs font-medium text-ink-soft underline underline-offset-4 hover:text-alert-600"
      @click="cancelOpen = true"
    >
      Salah buka? Batalkan buka kasir
    </button>

    <Dialog v-model:visible="countOpen" header="Hitung kas" modal class="w-full max-w-4xl">
      <form class="space-y-4" @submit.prevent="submitCount">
        <p class="text-sm text-ink-soft">
          Hitung uang di laci tanpa melihat catatan sistem. Hasilnya dicatat dan dibandingkan supervisor; kasir tetap terbuka.
        </p>
        <DenominationCounter v-model="quantities" :denominations="cashier.denominations" id-prefix="mid" />
        <Textarea v-model="countNote" rows="2" maxlength="500" class="w-full" placeholder="Catatan (opsional)" aria-label="Catatan hitungan" />
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="countOpen = false" />
          <Button label="Simpan hitungan" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>

    <Dialog v-model:visible="cancelOpen" header="Batalkan buka kasir" modal class="w-full max-w-md">
      <form class="space-y-4" @submit.prevent="submitCancel">
        <p class="text-sm text-ink-soft">
          Hanya untuk kasir yang salah dibuka (salah terminal atau salah hitung modal) dan belum ada transaksi.
          Pembatalan tercatat di audit log.
        </p>
        <div>
          <label for="cancel-reason" class="mb-1 block text-sm font-medium">Alasan</label>
          <Textarea id="cancel-reason" v-model="cancelReason" rows="3" maxlength="500" class="w-full" />
          <p class="mt-1 text-xs text-ink-faint">Minimal 5 karakter.</p>
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Kembali" text severity="secondary" type="button" @click="cancelOpen = false" />
          <Button label="Batalkan buka kasir" severity="danger" type="submit" :disabled="cancelReason.trim().length < 5" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </section>
</template>
