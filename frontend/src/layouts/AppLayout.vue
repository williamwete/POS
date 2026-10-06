<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Button from 'primevue/button'
import { useSessionStore } from '@/stores/session'
import { formatBusinessDate } from '@/utils/format'
import { routes, type PermissionRequirement } from '@/router'
import { useAttendanceStore } from '@/stores/attendance'
import BreakLockScreen from '@/modules/attendance/BreakLockScreen.vue'
import TerminalLockScreen from '@/modules/cashier/TerminalLockScreen.vue'
import { useCashierStore } from '@/stores/cashier'
import { useSaleStore } from '@/stores/sale'
import { useIdleLock } from '@/composables/useIdleLock'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()
const navOpen = ref(false)
const attendance = useAttendanceStore()
const cashier = useCashierStore()
const saleStore = useSaleStore()

// Status kehadiran & kasir dibutuhkan di semua halaman (layar kunci istirahat / terminal).
// Kasir dimuat ulang berkala agar kunci dari tempat lain (mis. force clock out) ikut terlihat.
let poll: number | undefined
onMounted(() => {
  if (!session.me?.employee) return
  if (!attendance.loaded) void attendance.load().catch(() => undefined)
  if (!cashier.loaded) void cashier.load().catch(() => undefined)
  poll = window.setInterval(() => {
    if (cashier.current) void Promise.all([cashier.load(), attendance.load()]).catch(() => undefined)
  }, 60_000)
})
onBeforeUnmount(() => window.clearInterval(poll))
useIdleLock()

watch(() => route.fullPath, () => (navOpen.value = false))

interface NavItem {
  name: string
  label: string
  icon: string
}

const ADMIN_NAV: NavItem[] = [
  { name: 'outlets', label: 'Outlet', icon: 'pi pi-building' },
  { name: 'terminals', label: 'Terminal & device', icon: 'pi pi-desktop' },
  { name: 'employees', label: 'Karyawan', icon: 'pi pi-id-card' },
  { name: 'users', label: 'User & akses', icon: 'pi pi-users' },
  { name: 'roles', label: 'Role & permission', icon: 'pi pi-shield' },
  { name: 'payment-methods', label: 'Metode pembayaran', icon: 'pi pi-wallet' },
  { name: 'audit', label: 'Audit log', icon: 'pi pi-history' },
]

function allowed(name: string): boolean {
  const def = routes[1]?.children?.find((r) => r.name === name)
  const reqs = (def?.meta as { anyOf?: PermissionRequirement[] } | undefined)?.anyOf
  return !reqs || reqs.some((r) => session.can(r.permission, r.scope))
}

const adminNav = computed(() => ADMIN_NAV.filter((n) => allowed(n.name)))
const outlet = computed(() => session.currentOutlet)
const initials = computed(() =>
  (session.me?.user.displayName ?? '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join(''),
)

async function logout() {
  attendance.reset()
  cashier.reset()
  saleStore.reset()
  await session.logout()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div class="min-h-screen bg-field text-ink lg:flex">
    <!-- ================= sidebar -->
    <nav
      id="side-nav"
      :class="[
        'fixed inset-y-0 left-0 z-40 flex w-64 shrink-0 flex-col border-r border-line bg-surface transition-transform lg:sticky lg:top-0 lg:h-screen lg:translate-x-0',
        navOpen ? 'translate-x-0' : '-translate-x-full',
      ]"
      aria-label="Navigasi utama"
    >
      <RouterLink :to="{ name: 'home' }" class="flex items-center gap-3 px-6 py-5">
        <span class="grid h-9 w-9 place-items-center rounded-xl bg-jade-600 text-base font-bold text-white">P</span>
        <span class="min-w-0 leading-tight">
          <span class="block truncate text-sm font-bold">{{ session.me?.organization.name }}</span>
          <span class="block text-xs text-ink-faint">Point of Sale</span>
        </span>
      </RouterLink>

      <div class="flex-1 overflow-y-auto px-3 pb-4">
        <ul class="space-y-1">
          <li>
            <RouterLink :to="{ name: 'home' }" class="nav-link" active-class="nav-link-active" exact-active-class="nav-link-active">
              <i class="pi pi-th-large" /> Beranda
            </RouterLink>
          </li>
          <li v-if="session.me?.employee && cashier.current && allowed('pos')">
            <RouterLink :to="{ name: 'pos' }" class="nav-link" active-class="nav-link-active">
              <i class="pi pi-shopping-cart" /> Transaksi
            </RouterLink>
          </li>
          <li v-if="session.me?.employee && session.can('cashier.open') && !cashier.current">
            <RouterLink :to="{ name: 'cashier-open' }" class="nav-link" active-class="nav-link-active">
              <i class="pi pi-wallet" /> Buka kasir
            </RouterLink>
          </li>
          <li v-if="session.me?.employee">
            <RouterLink :to="{ name: 'my-attendance' }" class="nav-link" active-class="nav-link-active">
              <i class="pi pi-clock" /> Kehadiran saya
            </RouterLink>
          </li>
          <li v-if="allowed('cashier-sessions')">
            <RouterLink :to="{ name: 'cashier-sessions' }" class="nav-link" active-class="nav-link-active">
              <i class="pi pi-inbox" /> Sesi kasir
            </RouterLink>
          </li>
          <li v-if="allowed('outlet-attendance')">
            <RouterLink :to="{ name: 'outlet-attendance' }" class="nav-link" active-class="nav-link-active">
              <i class="pi pi-calendar" /> Kehadiran outlet
            </RouterLink>
          </li>
        </ul>
        <template v-if="adminNav.length">
          <p class="px-3 pb-1 pt-5 text-[11px] font-semibold uppercase tracking-wider text-ink-faint">Administrasi</p>
          <ul class="space-y-1">
            <li v-for="item in adminNav" :key="item.name">
              <RouterLink :to="{ name: item.name }" class="nav-link" active-class="nav-link-active">
                <i :class="item.icon" /> {{ item.label }}
              </RouterLink>
            </li>
          </ul>
        </template>
      </div>

      <div class="border-t border-line px-3 py-3">
        <button type="button" class="nav-link w-full" @click="logout"><i class="pi pi-sign-out" /> Keluar</button>
      </div>
    </nav>
    <div v-if="navOpen" class="fixed inset-0 z-30 bg-ink/30 lg:hidden" @click="navOpen = false" />

    <!-- ================= konten -->
    <div class="flex min-w-0 flex-1 flex-col">
      <!-- bar konteks: selalu menunjukkan DI MANA dan KAPAN (business date) user bekerja -->
      <header class="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-line bg-surface/95 px-4 backdrop-blur sm:px-6">
        <button class="grid h-9 w-9 place-items-center rounded-lg hover:bg-field lg:hidden" :aria-expanded="navOpen"
          aria-controls="side-nav" aria-label="Buka menu" @click="navOpen = !navOpen">
          <i class="pi pi-bars" />
        </button>

        <div class="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto">
          <template v-if="outlet">
            <span class="ctx-chip hidden sm:inline-flex">
              <i class="pi pi-building text-ink-faint" aria-hidden="true" />
              <span class="truncate"><span class="tabular font-semibold">{{ outlet.code }}</span> {{ outlet.name }}</span>
            </span>
            <span v-if="session.terminal" class="ctx-chip !border-jade-500/40 !bg-jade-50 text-jade-700">
              <i class="pi pi-desktop" aria-hidden="true" />
              <span class="tabular font-semibold">{{ session.terminal.code }}</span>
            </span>
            <span v-if="cashier.current" class="ctx-chip" :title="`Kasir ${cashier.current.terminalCode}`">
              <span :class="['h-2 w-2 rounded-full', cashier.isOpen ? 'bg-jade-500' : 'bg-amber-500']" aria-hidden="true" />
              Kasir {{ cashier.isOpen ? 'buka' : 'terkunci' }}
              <span v-if="cashier.current.terminalId !== session.terminal?.id" class="tabular text-ink-faint">di {{ cashier.current.terminalCode }}</span>
            </span>
            <span class="ctx-chip hidden md:inline-flex">
              <i class="pi pi-calendar text-ink-faint" aria-hidden="true" />
              {{ formatBusinessDate(outlet.businessDate) }}
            </span>
          </template>
          <RouterLink v-else :to="{ name: 'context' }" class="text-sm font-semibold text-jade-700 underline underline-offset-4">
            Pilih outlet & terminal
          </RouterLink>
        </div>

        <Button v-if="outlet" icon="pi pi-sync" text rounded severity="secondary" aria-label="Ganti outlet atau terminal"
          v-tooltip.bottom="'Ganti outlet / terminal'" @click="router.push({ name: 'context' })" />
        <div class="flex shrink-0 items-center gap-3 border-l border-line pl-3">
          <span class="grid h-9 w-9 place-items-center rounded-full bg-jade-50 text-sm font-bold text-jade-700" aria-hidden="true">
            {{ initials }}
          </span>
          <div class="hidden leading-tight xl:block">
            <div class="text-sm font-semibold">{{ session.me?.user.displayName }}</div>
            <div class="max-w-[14rem] truncate text-xs text-ink-faint">{{ session.roleSummary.join(', ') }}</div>
          </div>
        </div>
      </header>

      <main class="min-w-0 flex-1 p-4 sm:p-6">
        <RouterView />
      </main>
    </div>
    <BreakLockScreen />
    <TerminalLockScreen />
  </div>
</template>

<style scoped>
.nav-link {
  @apply flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-ink-soft transition hover:bg-field hover:text-ink;
}
.nav-link i {
  @apply text-base;
}
.nav-link-active {
  @apply bg-jade-50 font-semibold text-jade-700;
}
.ctx-chip {
  @apply inline-flex shrink-0 items-center gap-2 rounded-full border border-line bg-surface px-3 py-1.5 text-xs text-ink;
}
</style>
