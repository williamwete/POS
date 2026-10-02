<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import Button from 'primevue/button'
import Password from 'primevue/password'
import { useSessionStore } from '@/stores/session'
import { useAttendanceStore } from '@/stores/attendance'
import { useCashierStore } from '@/stores/cashier'
import { useApiAction } from '@/composables/useApiAction'

/**
 * Layar kunci terminal (session lock). Membuka kunci WAJIB memasukkan password lagi:
 * database menolak unlock dengan token yang terbit sebelum terminal dikunci.
 * Saat istirahat, BreakLockScreen yang tampil; layar ini muncul setelah istirahat selesai.
 */
const session = useSessionStore()
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const router = useRouter()
const { busy, run } = useApiAction()
const password = ref('')

const visible = computed(() => cashier.isLocked && !attendance.isOnBreak)
const s = computed(() => cashier.current)
const needsClockIn = computed(() => !attendance.current)

const reasonText = computed(() => {
  switch (s.value?.lockReason) {
    case 'IDLE': return 'Dikunci otomatis karena tidak ada aktivitas.'
    case 'BREAK': return 'Istirahat selesai. Masukkan password untuk melanjutkan.'
    case 'FORCED_CLOCK_OUT': return 'Kehadiran Anda ditutup oleh supervisor. Clock in lagi untuk melanjutkan.'
    default: return 'Terminal dikunci.'
  }
})
const lockedSince = computed(() =>
  s.value?.lockedAt
    ? new Intl.DateTimeFormat('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' }).format(new Date(s.value.lockedAt))
    : '',
)

watch(visible, async (v) => {
  password.value = ''
  if (v) {
    await nextTick()
    document.getElementById('unlock-password')?.focus()
  }
})

async function clockIn() {
  const outletId = s.value?.outletId
  if (outletId) await run((key) => attendance.clockIn(outletId, key), 'Clock in tercatat')
}

async function unlock() {
  if (!password.value) return
  const pwd = password.value
  password.value = ''
  await run(async (key) => {
    await session.reauthenticate(pwd)
    await cashier.unlock(key)
  }, 'Terminal dibuka')
}

async function logout() {
  attendance.reset()
  cashier.reset()
  await session.logout()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div
    v-if="visible"
    class="fixed inset-0 z-50 flex items-center justify-center bg-ink/95 p-6 text-white"
    role="dialog"
    aria-modal="true"
    aria-labelledby="lock-title"
  >
    <div class="w-full max-w-sm text-center">
      <div class="mx-auto grid h-16 w-16 place-items-center rounded-full bg-amber-500 text-jade-900">
        <i class="pi pi-lock text-2xl" aria-hidden="true" />
      </div>
      <h2 id="lock-title" class="mt-4 text-3xl font-bold">Terminal terkunci</h2>
      <p class="mt-2 text-sm text-white/70">
        <span class="tabular font-semibold text-white">{{ s?.terminalCode }}</span> ·
        {{ s?.employeeName }}<template v-if="lockedSince"> · sejak <span class="tabular">{{ lockedSince }}</span></template>
      </p>
      <p class="mt-4 text-white/90">{{ reasonText }}</p>

      <Button v-if="needsClockIn" class="mt-6" label="Clock in" icon="pi pi-sign-in" size="large" :loading="busy" @click="clockIn" />

      <form v-else class="mt-6 space-y-3 text-left" @submit.prevent="unlock">
        <label for="unlock-password" class="block text-sm font-medium text-white/80">
          Password {{ session.me?.user.email }}
        </label>
        <Password
          v-model="password"
          input-id="unlock-password"
          :feedback="false"
          toggle-mask
          class="w-full"
          input-class="w-full"
          autocomplete="current-password"
        />
        <Button type="submit" label="Buka kunci" icon="pi pi-lock-open" class="w-full" :disabled="!password" :loading="busy" />
      </form>

      <button type="button" class="mt-6 text-sm text-white/70 underline underline-offset-4 hover:text-white" @click="logout">
        Bukan Anda? Keluar
      </button>
    </div>
  </div>
</template>
