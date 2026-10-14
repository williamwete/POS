<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Button from 'primevue/button'
import { useSessionStore } from '@/stores/session'
import { useBrandStore } from '@/stores/brand'
import { formatBusinessDate } from '@/utils/format'
import { routes, type PermissionRequirement } from '@/router'
import { useAttendanceStore } from '@/stores/attendance'
import BreakLockScreen from '@/modules/attendance/BreakLockScreen.vue'
import TerminalLockScreen from '@/modules/cashier/TerminalLockScreen.vue'
import { useCashierStore } from '@/stores/cashier'
import { useSaleStore } from '@/stores/sale'
import { useIdleLock } from '@/composables/useIdleLock'
import { useMenuStore } from '@/stores/menu'
import TrialBanner from '@/components/TrialBanner.vue'
import OfflineBanner from '@/components/OfflineBanner.vue'
import { useOfflineStore } from '@/stores/offline'

const session = useSessionStore()
const brand = useBrandStore()
const router = useRouter()
const route = useRoute()
const navOpen = ref(false)
const attendance = useAttendanceStore()
const offline = useOfflineStore()
const cashier = useCashierStore()
const saleStore = useSaleStore()
const menus = useMenuStore()

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

// Menu samping mengikuti role (dan pengaturan Owner/Admin); dimuat ulang saat outlet berganti.
watch(() => session.outletId, (id) => void menus.load(id), { immediate: true })
const MENU_ICON: Record<string, string> = {
  pos: 'pi pi-th-large', clock: 'pi pi-clock', 'beginning-cash': 'pi pi-wallet', 'product-list': 'pi pi-box',
  history: 'pi pi-history', 'manage-categories': 'pi pi-tags', 'manage-discount': 'pi pi-percentage',
  'manage-cashier': 'pi pi-users', 'manage-receipt': 'pi pi-print', closing: 'pi pi-lock', dashboard: 'pi pi-chart-bar',
}
// hanya menu yang halamannya sudah ada; menu beranda tidak dobel dengan Dashboard
const menuNav = computed(() => menus.items.filter((m) => router.hasRoute(m.routeName)))

interface NavItem {
  name: string
  label: string
  icon: string
}

// Outlet, Sinkronisasi dan Pemetaan Openbravo sengaja tidak ada di sini: halamannya mengelola data organisasi
// pengguna yang login, jadi tidak berguna bagi operator platform dan disembunyikan dari pemilik toko.
// Rutenya tetap terkunci (platform.manage) sampai ada tampilan kelola per merchant di konsol platform.
const ADMIN_NAV: NavItem[] = [
  { name: 'menu-access', label: 'Akses menu', icon: 'pi pi-sliders-h' },
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
  offline.reset()
  menus.reset()
  cashier.reset()
  saleStore.reset()
  await session.logout()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div class="min-h-screen bg-field text-ink">
    <!-- ================= sidebar -->
    <nav
      id="side-nav"
      :class="[
        'fixed inset-y-0 left-0 z-40 flex w-64 shrink-0 flex-col border-r border-line bg-surface shadow-xl transition-transform',
        navOpen ? 'translate-x-0' : '-translate-x-full',
      ]"
      aria-label="Navigasi utama"
    >
      <RouterLink :to="{ name: 'home' }" class="flex items-center gap-3 px-6 py-5">
        <img v-if="brand.logo" :src="brand.logo" alt="" class="h-9 w-9 rounded-xl object-contain" />
        <span v-else class="grid h-9 w-9 place-items-center rounded-xl bg-jade-500 text-base font-bold text-white">{{ brand.name.charAt(0).toUpperCase() }}</span>
        <span class="min-w-0 leading-tight">
          <span class="block truncate text-sm font-bold">{{ brand.name }}</span>
          <span class="block text-xs text-ink-faint">CuanRena POS</span>
        </span>
      </RouterLink>

      <div class="flex-1 overflow-y-auto px-3 pb-4">
        <ul class="space-y-1">
          <li v-for="m in menuNav" :key="m.code">
            <RouterLink :to="{ name: m.routeName }" class="nav-link" active-class="nav-link-active" :exact-active-class="m.routeName === 'home' ? 'nav-link-active' : undefined">
              <i :class="MENU_ICON[m.code] ?? 'pi pi-circle'" /> {{ m.label }}
            </RouterLink>
          </li>
          <li v-if="!menus.items.length">
            <RouterLink :to="{ name: 'home' }" class="nav-link" exact-active-class="nav-link-active"><i class="pi pi-th-large" /> Beranda</RouterLink>
          </li>
          <li v-if="allowed('cashier-sessions')">
            <RouterLink :to="{ name: 'cashier-sessions' }" class="nav-link" active-class="nav-link-active"><i class="pi pi-inbox" /> Sesi kasir</RouterLink>
          </li>
          <li v-if="allowed('daily-recap')">
            <RouterLink :to="{ name: 'daily-recap' }" class="nav-link" active-class="nav-link-active"><i class="pi pi-calendar-clock" /> Rekap harian</RouterLink>
          </li>
          <li v-if="allowed('sales-report')">
            <RouterLink :to="{ name: 'sales-report' }" class="nav-link" active-class="nav-link-active"><i class="pi pi-file-export" /> Laporan penjualan</RouterLink>
          </li>
          <li v-if="allowed('outlet-attendance')">
            <RouterLink :to="{ name: 'outlet-attendance' }" class="nav-link" active-class="nav-link-active"><i class="pi pi-calendar" /> Kehadiran outlet</RouterLink>
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
    <div v-if="navOpen" class="fixed inset-0 z-30 bg-ink/30" @click="navOpen = false" />

    <!-- ================= konten -->
    <div class="flex min-h-screen min-w-0 flex-col">
      <!-- bar konteks: selalu menunjukkan DI MANA dan KAPAN (business date) user bekerja -->
      <header class="sticky top-0 z-20 flex h-16 items-center gap-3 bg-jade-100 px-4 sm:px-6">
        <span class="flex items-center gap-2 text-2xl font-bold tracking-tight">
          <img v-if="brand.logo" :src="brand.logo" alt="" class="h-8 w-8 rounded-lg object-contain" />
          <span class="max-w-[14rem] truncate">{{ brand.name }}</span>
        </span>

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
          <RouterLink v-else-if="session.me?.outlets.length" :to="{ name: 'context' }" class="text-sm font-semibold text-jade-700 underline underline-offset-4">
            Pilih outlet & terminal
          </RouterLink>
        </div>

        <Button v-if="outlet" icon="pi pi-sync" text rounded severity="secondary" aria-label="Ganti outlet atau terminal"
          v-tooltip.bottom="'Ganti outlet / terminal'" @click="router.push({ name: 'context' })" />
        <div class="flex shrink-0 items-center gap-3 border-l border-ink/10 pl-3">
          <span class="grid h-9 w-9 place-items-center rounded-full bg-jade-50 text-sm font-bold text-jade-700" aria-hidden="true">
            {{ initials }}
          </span>
          <div class="hidden leading-tight xl:block">
            <div class="text-sm font-semibold">{{ session.me?.user.displayName }}</div>
            <div class="max-w-[14rem] truncate text-xs text-ink-faint">{{ session.roleSummary.join(', ') }}</div>
          </div>
          <button type="button" class="grid h-9 w-9 place-items-center rounded-lg hover:bg-white/60" aria-label="Keluar"
            v-tooltip.bottom="'Keluar'" @click="logout"><i class="pi pi-sign-out text-lg" /></button>
        </div>
      </header>

      <div class="flex min-w-0 flex-1">
        <aside class="sticky top-16 hidden h-[calc(100vh-4rem)] w-14 shrink-0 flex-col items-center border-r border-line bg-jade-100 pt-4 sm:flex">
          <button class="grid h-10 w-10 place-items-center rounded-lg hover:bg-white/60" :aria-expanded="navOpen"
            aria-controls="side-nav" aria-label="Buka menu" @click="navOpen = !navOpen">
            <i class="pi pi-bars text-lg" />
          </button>
        </aside>
        <main class="min-w-0 flex-1 p-4 sm:p-6">
          <button class="mb-3 grid h-9 w-9 place-items-center rounded-lg bg-jade-100 sm:hidden" aria-label="Buka menu" @click="navOpen = !navOpen">
            <i class="pi pi-bars" />
          </button>
          <TrialBanner />
          <OfflineBanner />
          <RouterView />
        </main>
      </div>
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
  @apply inline-flex shrink-0 items-center gap-2 rounded-full border border-line bg-white/70 px-3 py-1.5 text-xs text-ink;
}
</style>
