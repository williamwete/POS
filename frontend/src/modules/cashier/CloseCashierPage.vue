<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Select from 'primevue/select'
import Textarea from 'primevue/textarea'
import ProgressSpinner from 'primevue/progressspinner'
import { useConfirm } from 'primevue/useconfirm'
import { useSessionStore } from '@/stores/session'
import { useAttendanceStore } from '@/stores/attendance'
import { toCountLines, useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'
import type { CashierSession, ClosePreview, DifferenceReason } from '@/types/api'
import { countTotal, formatRupiah } from '@/utils/money'
import { formatDateTime } from '@/utils/format'
import DenominationCounter from './DenominationCounter.vue'
import CashApprovalDialog from './CashApprovalDialog.vue'
import ShiftReportDialog from './ShiftReportDialog.vue'
import { DIFFERENCE_REASON_LABEL, signedRupiah } from './cashierFormat'

/**
 * Tutup kasir (§48–§51): hitung fisik per pecahan tanpa melihat catatan sistem → periksa selisih →
 * alasan & approval bila perlu → tutup. Semua angka (expected, selisih) dihitung server; setiap
 * pemeriksaan tercatat di audit. Pemilik langsung bisa clock out setelahnya.
 */
const route = useRoute()
const router = useRouter()
const confirm = useConfirm()
const session = useSessionStore()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const { busy, run } = useApiAction()

type Step = 'count' | 'review' | 'done'
const step = ref<Step>('count')
const loading = ref(true)
const target = ref<CashierSession | null>(null)
const quantities = ref<Record<string, number | null>>({})
const preview = ref<ClosePreview | null>(null)
const reason = ref<DifferenceReason | null>(null)
const diffNote = ref('')
const approvalId = ref<string | null>(null)
const approverName = ref<string | null>(null)
const approvalOpen = ref(false)
const closed = ref<CashierSession | null>(null)
const zOpen = ref(false)

const otherSessionId = computed(() => (typeof route.query.session === 'string' ? route.query.session : null))

onMounted(async () => {
  try {
    await Promise.all([cashier.loadDenominations(), cashier.load(), attendance.load()])
    if (otherSessionId.value && otherSessionId.value !== cashier.current?.id) {
      target.value = await run(() => cashier.get(otherSessionId.value!))
    } else {
      target.value = cashier.current
    }
  } finally {
    loading.value = false
  }
})

const isOwner = computed(() => !!target.value && target.value.employeeId === session.me?.employee?.id)
const values = computed(() => new Map(cashier.denominations.map((d) => [d.id, d.value])))
const total = computed(() => countTotal(values.value, quantities.value))
const active = computed(() => !!target.value && ['OPEN', 'ON_BREAK'].includes(target.value.status))

const REASONS = (Object.keys(DIFFERENCE_REASON_LABEL) as DifferenceReason[]).map((value) => ({
  value,
  label: DIFFERENCE_REASON_LABEL[value],
}))

const blocked = computed(() => {
  const p = preview.value
  if (!p) return null
  if (p.pendingPayments > 0) return `Masih ada ${p.pendingPayments} pembayaran yang menunggu konfirmasi penyedia.`
  if (p.pendingReturns > 0) return `Masih ada ${p.pendingReturns} retur yang menunggu persetujuan. Setujui atau tolak di menu Retur.`
  if (p.openOrders > 0 && !p.allowCloseWithOpenOrders) {
    return `Masih ada ${p.openOrders} transaksi terbuka atau ditahan. Selesaikan, void, atau batalkan dulu.`
  }
  return null
})

const reasonOk = computed(() => {
  if (!preview.value?.reasonRequired) return true
  if (!reason.value) return false
  return reason.value !== 'OTHER' || diffNote.value.trim().length >= 5
})
const approvalOk = computed(() => !preview.value?.approvalRequired || !!approvalId.value)
const canClose = computed(() => !!preview.value && !blocked.value && reasonOk.value && approvalOk.value)

async function check() {
  if (!target.value) return
  const p = await run(() => cashier.closePreview(target.value!.id, toCountLines(quantities.value)))
  if (!p) return
  preview.value = p
  if (!p.reasonRequired) {
    reason.value = null
    diffNote.value = ''
  } else if (!reason.value) {
    reason.value = p.difference < 0 ? 'SHORTAGE' : 'OVERAGE'
  }
  approvalId.value = null
  approverName.value = null
  step.value = 'review'
}

function recount() {
  step.value = 'count'
  preview.value = null
  approvalId.value = null
  approverName.value = null
}

function onApproved(id: string, name: string) {
  approvalId.value = id
  approverName.value = name
}

function submit() {
  const t = target.value
  const p = preview.value
  if (!t || !p || !canClose.value) return
  confirm.require({
    header: `Tutup kasir ${t.terminalCode}?`,
    message:
      p.difference === 0
        ? `Uang di laci ${formatRupiah(p.countedCash)}, sesuai catatan. Setelah ditutup, laci tidak bisa dipakai lagi.`
        : `Uang di laci ${formatRupiah(p.countedCash)}, selisih ${signedRupiah(p.difference)}. Setelah ditutup, laci tidak bisa dipakai lagi.`,
    acceptLabel: 'Tutup kasir',
    rejectLabel: 'Periksa lagi',
    accept: async () => {
      const res = await run(
        (key) => cashier.close(t.id, {
          counts: toCountLines(quantities.value),
          differenceReason: p.reasonRequired ? reason.value : null,
          differenceNote: p.reasonRequired ? diffNote.value.trim() || null : null,
          approvalId: approvalId.value,
        }, key),
        'Kasir ditutup',
      )
      if (res) {
        closed.value = res
        step.value = 'done'
      } else {
        // approval sudah dipakai/kedaluwarsa atau angka berubah: minta ulang
        approvalId.value = null
        approverName.value = null
      }
    },
  })
}

async function clockOut() {
  const ok = await run((key) => attendance.clockOut(key), 'Clock out tercatat')
  if (ok !== null) await router.push({ name: 'home' })
}
</script>

<template>
  <div class="mx-auto max-w-4xl">
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 class="text-2xl font-bold">Tutup kasir</h1>
        <p class="mt-1 text-ink-soft">
          <template v-if="step === 'count'">Hitung semua uang di laci per pecahan, tanpa melihat catatan sistem.</template>
          <template v-else-if="step === 'review'">Periksa hasil hitungan sebelum laci ditutup.</template>
          <template v-else>Laci kas sudah ditutup dan tercatat.</template>
        </p>
      </div>
      <div v-if="target" class="rounded-md bg-amber-500 px-3 py-1 text-jade-900">
        <div class="text-xs font-medium">Terminal</div>
        <div class="tabular text-lg font-bold">{{ target.terminalCode }}</div>
      </div>
    </div>

    <ol v-if="target && active" class="mt-5 flex gap-2 text-xs font-medium" aria-label="Langkah">
      <li v-for="(label, i) in ['Hitung uang', 'Periksa selisih', 'Selesai']" :key="label"
        :class="['flex items-center gap-2 rounded-full px-3 py-1',
                 ['count', 'review', 'done'].indexOf(step) >= i ? 'bg-jade-50 text-jade-700' : 'bg-field text-ink-faint']">
        <span class="tabular">{{ i + 1 }}</span>{{ label }}
      </li>
    </ol>

    <div v-if="loading" class="mt-10 flex justify-center"><ProgressSpinner style="width: 2.5rem; height: 2.5rem" /></div>

    <template v-else>
      <!-- tidak ada kasir aktif -->
      <div v-if="!target || (!active && step !== 'done')" class="mt-6 rounded-2xl border border-line bg-surface p-5">
        <p class="font-semibold">Tidak ada kasir aktif untuk ditutup.</p>
        <p class="mt-1 text-sm text-ink-soft">Kasir mungkin sudah ditutup atau dibatalkan.</p>
        <Button class="mt-4" label="Kembali ke beranda" severity="secondary" @click="router.push({ name: 'home' })" />
      </div>

      <!-- 1. hitung -->
      <form v-else-if="step === 'count'" class="mt-6 space-y-6" @submit.prevent="check">
        <Message v-if="!isOwner" severity="warn" :closable="false">
          Anda menutup laci milik <strong>{{ target.employeeName }}</strong> ({{ target.employeeCode }}). Hitung uang
          bersama saksi bila memungkinkan; penutupan tercatat atas nama Anda.
        </Message>
        <Message v-else-if="target.status === 'ON_BREAK'" severity="warn" :closable="false">
          Terminal sedang terkunci. Buka kunci terminal terlebih dahulu.
        </Message>
        <DenominationCounter v-model="quantities" :denominations="cashier.denominations" id-prefix="close" />
        <div class="flex flex-wrap justify-end gap-2">
          <Button label="Batal" severity="secondary" text type="button" @click="router.back()" />
          <Button :label="`Lanjut periksa · ${formatRupiah(total)}`" icon="pi pi-arrow-right" icon-pos="right"
            type="submit" :loading="busy" :disabled="isOwner && target.status === 'ON_BREAK'" />
        </div>
      </form>

      <!-- 2. periksa -->
      <div v-else-if="step === 'review' && preview" class="mt-6 space-y-5">
        <Message v-if="blocked" severity="error" :closable="false">
          {{ blocked }}
          <Button v-if="isOwner && preview.openOrders > 0" class="ml-2" label="Buka layar kasir" size="small" text
            @click="router.push({ name: 'pos' })" />
        </Message>

        <dl class="grid gap-px overflow-hidden rounded-2xl border border-line bg-line sm:grid-cols-3">
          <div class="bg-surface p-4">
            <dt class="text-sm text-ink-soft">Uang dihitung</dt>
            <dd class="tabular mt-1 text-2xl font-bold">{{ formatRupiah(preview.countedCash) }}</dd>
          </div>
          <div class="bg-surface p-4">
            <dt class="text-sm text-ink-soft">Seharusnya (catatan sistem)</dt>
            <dd class="tabular mt-1 text-2xl font-bold">{{ formatRupiah(preview.expectedCash) }}</dd>
          </div>
          <div :class="['p-4', preview.difference === 0 ? 'bg-jade-50' : 'bg-alert-50']">
            <dt :class="['text-sm', preview.difference === 0 ? 'text-jade-700' : 'text-alert-600']">Selisih</dt>
            <dd :class="['tabular mt-1 text-2xl font-bold', preview.difference === 0 ? 'text-jade-700' : 'text-alert-600']">
              {{ preview.difference === 0 ? 'Pas' : signedRupiah(preview.difference) }}
            </dd>
          </div>
        </dl>

        <section v-if="preview.reasonRequired" class="space-y-3 rounded-2xl border border-line bg-surface p-5">
          <h2 class="font-semibold">
            {{ preview.difference < 0 ? 'Uang kurang' : 'Uang lebih' }} {{ formatRupiah(Math.abs(preview.difference)) }}
          </h2>
          <p class="text-sm text-ink-soft">Periksa ulang hitungan bila ragu. Jika memang selisih, pilih alasannya.</p>
          <div class="grid gap-3 sm:grid-cols-2">
            <div>
              <label for="diff-reason" class="mb-1 block text-sm font-medium">Alasan selisih</label>
              <Select v-model="reason" input-id="diff-reason" :options="REASONS" option-label="label" option-value="value"
                class="w-full" />
            </div>
            <div>
              <label for="diff-note" class="mb-1 block text-sm font-medium">
                Keterangan <span class="font-normal text-ink-faint">{{ reason === 'OTHER' ? '(wajib)' : '(opsional)' }}</span>
              </label>
              <Textarea id="diff-note" v-model="diffNote" rows="2" maxlength="500" class="w-full" />
            </div>
          </div>

          <div v-if="preview.approvalRequired" class="flex flex-wrap items-center justify-between gap-3 rounded-md bg-amber-100 p-3 text-sm">
            <span v-if="!approvalId">
              Selisih melewati batas {{ formatRupiah(preview.approvalThreshold) }}: perlu persetujuan supervisor.
            </span>
            <span v-else class="text-jade-700"><i class="pi pi-check-circle" aria-hidden="true" /> Disetujui {{ approverName }}. Tutup dalam 2 menit.</span>
            <Button v-if="!approvalId" label="Minta persetujuan" icon="pi pi-user-plus" size="small" @click="approvalOpen = true" />
          </div>
        </section>

        <div class="flex flex-wrap justify-between gap-2">
          <Button label="Hitung ulang" icon="pi pi-arrow-left" severity="secondary" text @click="recount" />
          <Button label="Tutup kasir" icon="pi pi-lock" severity="danger" :loading="busy" :disabled="!canClose" @click="submit" />
        </div>

        <CashApprovalDialog
          v-model:visible="approvalOpen"
          :session-id="target.id"
          action="CASH_DIFFERENCE"
          :amount="Math.abs(preview.difference)"
          :message="`Selisih kas ${signedRupiah(preview.difference)} (${reason ? DIFFERENCE_REASON_LABEL[reason] : 'tanpa alasan'}).`"
          @approved="onApproved"
        />
      </div>

      <!-- 3. selesai -->
      <div v-else-if="step === 'done' && closed" class="mt-6 space-y-5">
        <div class="rounded-2xl border border-line bg-surface p-5">
          <div class="flex items-center gap-3">
            <span class="grid h-10 w-10 place-items-center rounded-full bg-jade-50 text-jade-700"><i class="pi pi-check" aria-hidden="true" /></span>
            <div>
              <p class="font-semibold">Kasir {{ closed.terminalCode }} ditutup</p>
              <p class="tabular text-sm text-ink-soft">{{ formatDateTime(closed.closedAt) }} · oleh {{ closed.closedByName }}</p>
            </div>
          </div>
          <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-4">
            <div><dt class="text-ink-soft">Modal awal</dt><dd class="tabular font-semibold">{{ formatRupiah(closed.openingCash) }}</dd></div>
            <div><dt class="text-ink-soft">Seharusnya</dt><dd class="tabular font-semibold">{{ formatRupiah(closed.expectedCash) }}</dd></div>
            <div><dt class="text-ink-soft">Dihitung</dt><dd class="tabular font-semibold">{{ formatRupiah(closed.closingCash) }}</dd></div>
            <div>
              <dt class="text-ink-soft">Selisih</dt>
              <dd :class="['tabular font-semibold', Number(closed.difference) === 0 ? 'text-jade-700' : 'text-alert-600']">
                {{ signedRupiah(closed.difference) }}
              </dd>
            </div>
          </dl>
          <p v-if="closed.differenceReason" class="mt-3 text-sm text-ink-soft">
            Alasan: {{ DIFFERENCE_REASON_LABEL[closed.differenceReason] }}<template v-if="closed.differenceNote"> — {{ closed.differenceNote }}</template>
            <template v-if="closed.differenceApprovedByName"> · disetujui {{ closed.differenceApprovedByName }}</template>
          </p>
          <p class="mt-3 text-sm text-ink-soft">Serahkan uang laci ke brankas sesuai prosedur outlet.</p>
        </div>
        <div class="flex flex-wrap justify-end gap-2">
          <Button label="Z report" icon="pi pi-print" severity="secondary" @click="zOpen = true" />
          <template v-if="isOwner">
            <Button label="Ke beranda" severity="secondary" text @click="router.push({ name: 'home' })" />
            <Button v-if="attendance.current?.status === 'WORKING'" label="Clock out sekarang" icon="pi pi-sign-out"
              :loading="busy" @click="clockOut" />
          </template>
          <Button v-else label="Kembali ke sesi kasir" @click="router.push({ name: 'cashier-sessions' })" />
        </div>
        <ShiftReportDialog v-model:visible="zOpen" :session-id="closed.id" type="Z" />
      </div>
    </template>
  </div>
</template>
