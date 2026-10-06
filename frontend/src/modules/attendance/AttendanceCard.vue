<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import { useConfirm } from 'primevue/useconfirm'
import { useToast } from 'primevue/usetoast'
import { useSessionStore } from '@/stores/session'
import { formatDuration, useAttendanceStore, workedSeconds } from '@/stores/attendance'
import { useApiAction } from '@/composables/useApiAction'
import { useCashierStore } from '@/stores/cashier'

const session = useSessionStore()
const attendance = useAttendanceStore()
const confirm = useConfirm()
const cashier = useCashierStore()
const toast = useToast()
const { busy, run } = useApiAction()

const now = ref(new Date())
let timer: number | undefined
onMounted(() => {
  timer = window.setInterval(() => (now.value = new Date()), 15_000)
  if (!attendance.loaded) void run(() => attendance.load())
})
onBeforeUnmount(() => window.clearInterval(timer))

const hasEmployee = computed(() => !!session.me?.employee)
const canClockIn = computed(() => session.can('attendance.clock_in'))
const current = computed(() => attendance.current)
const atOtherOutlet = computed(() => !!current.value && current.value.outletId !== session.outletId)

const timeFmt = new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' })
const since = computed(() => (current.value ? timeFmt.format(new Date(current.value.clockIn)) : ''))
const worked = computed(() => (current.value ? formatDuration(workedSeconds(current.value, now.value)) : ''))

const breakOpen = ref(false)
const breakReason = ref('')

async function clockIn() {
  if (!session.outletId) return
  await run((key) => attendance.clockIn(session.outletId!, key), 'Clock in tercatat')
}

async function startBreak() {
  const ok = await run((key) => attendance.startBreak(breakReason.value.trim() || null, key), 'Istirahat dimulai')
  if (ok !== null) {
    // istirahat mengunci kasir yang sedang terbuka (dilakukan server)
    if (cashier.current) void cashier.load().catch(() => undefined)
    breakOpen.value = false
    breakReason.value = ''
  }
}

function clockOut() {
  if (cashier.current) {
    toast.add({
      severity: 'warn',
      summary: 'Kasir masih terbuka',
      detail: `Anda masih memegang kasir ${cashier.current.terminalCode}. Tutup kasir (atau batalkan bila salah buka) sebelum clock out.`,
      life: 6000,
    })
    return
  }
  confirm.require({
    header: 'Clock out sekarang?',
    message: `Jam kerja hari ini ${worked.value}. Setelah clock out Anda perlu clock in lagi untuk mulai bekerja.`,
    acceptLabel: 'Clock out',
    rejectLabel: 'Batal',
    accept: () => void run((key) => attendance.clockOut(key), 'Clock out tercatat'),
  })
}
</script>

<template>
  <section v-if="hasEmployee" class="rounded-2xl border border-line bg-surface p-5" aria-labelledby="att-title">
    <div class="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h2 id="att-title" class="text-lg font-semibold">Kehadiran</h2>
        <p v-if="!current" class="text-sm text-ink-soft">Anda sedang tidak clock in.</p>
        <p v-else-if="current.status === 'WORKING'" class="text-sm text-ink-soft">
          Bekerja sejak <span class="tabular font-semibold text-ink">{{ since }}</span> di {{ current.outletCode }}.
          Jam kerja bersih <span class="tabular font-semibold text-ink">{{ worked }}</span>.
        </p>
        <p v-else class="text-sm text-ink-soft">Sedang istirahat.</p>
        <p v-if="atOtherOutlet" class="mt-1 text-sm text-amber-700">
          Anda clock in di outlet {{ current?.outletCode }}, bukan outlet yang sedang dipilih.
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <Button
          v-if="!current"
          label="Clock in"
          icon="pi pi-sign-in"
          :disabled="!canClockIn || !session.outletId"
          :loading="busy"
          @click="clockIn"
        />
        <template v-else-if="current.status === 'WORKING'">
          <Button label="Mulai istirahat" icon="pi pi-pause" severity="secondary" :loading="busy" @click="breakOpen = true" />
          <Button label="Clock out" icon="pi pi-sign-out" severity="contrast" outlined :loading="busy" @click="clockOut" />
        </template>
      </div>
    </div>
    <p v-if="!current && !canClockIn" class="mt-3 text-xs text-ink-faint">
      Role Anda tidak memiliki izin clock in di outlet ini.
    </p>

    <Dialog v-model:visible="breakOpen" header="Mulai istirahat" modal class="w-full max-w-sm">
      <form class="space-y-4" @submit.prevent="startBreak">
        <p class="text-sm text-ink-soft">Layar POS akan terkunci sampai Anda menekan "Selesai istirahat".</p>
        <div>
          <label for="break-reason" class="mb-1 block text-sm font-medium">Keterangan (opsional)</label>
          <InputText id="break-reason" v-model="breakReason" class="w-full" maxlength="200" placeholder="Mis. makan siang, sholat" />
        </div>
        <div class="flex justify-end gap-2">
          <Button label="Batal" text severity="secondary" type="button" @click="breakOpen = false" />
          <Button label="Mulai istirahat" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>
  </section>
</template>
