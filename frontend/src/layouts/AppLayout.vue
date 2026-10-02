<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Button from 'primevue/button'
import { useSessionStore } from '@/stores/session'
import { formatBusinessDate } from '@/utils/format'
import { routes, type PermissionRequirement } from '@/router'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()
const navOpen = ref(false)

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
  { name: 'audit', label: 'Audit log', icon: 'pi pi-history' },
]

function allowed(name: string): boolean {
  const def = routes[1]?.children?.find((r) => r.name === name)
  const reqs = (def?.meta as { anyOf?: PermissionRequirement[] } | undefined)?.anyOf
  return !reqs || reqs.some((r) => session.can(r.permission, r.scope))
}

const adminNav = computed(() => ADMIN_NAV.filter((n) => allowed(n.name)))
const outlet = computed(() => session.currentOutlet)

async function logout() {
  await session.logout()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div class="min-h-screen bg-field text-ink">
    <!-- Strip konteks: selalu menunjukkan DI MANA dan KAPAN (business date) user bekerja -->
    <header class="sticky top-0 z-30 border-b border-jade-900 bg-jade-700 text-white">
      <div class="flex items-stretch gap-0">
        <button
          class="flex items-center px-4 lg:hidden"
          :aria-expanded="navOpen"
          aria-controls="side-nav"
          aria-label="Buka menu"
          @click="navOpen = !navOpen"
        >
          <i class="pi pi-bars text-lg" />
        </button>

        <RouterLink :to="{ name: 'home' }" class="flex items-center gap-3 px-4 py-3 lg:w-60 lg:border-r lg:border-jade-600">
          <span class="grid h-8 w-8 place-items-center rounded-md bg-white/10 text-sm font-bold">P</span>
          <span class="hidden text-sm font-semibold leading-tight sm:block">
            {{ session.me?.organization.name }}
          </span>
        </RouterLink>

        <div class="flex min-w-0 flex-1 items-center gap-4 overflow-x-auto px-4 py-2">
          <template v-if="outlet">
            <div class="min-w-0">
              <div class="text-xs text-jade-100">Outlet</div>
              <div class="truncate text-sm font-semibold">
                <span class="tabular">{{ outlet.code }}</span> {{ outlet.name }}
              </div>
            </div>
            <div v-if="session.terminal" class="shrink-0 rounded-md bg-amber-500 px-3 py-1 text-jade-900">
              <div class="text-xs font-medium">Terminal</div>
              <div class="tabular text-sm font-bold">{{ session.terminal.code }}</div>
            </div>
            <div class="hidden shrink-0 md:block">
              <div class="text-xs text-jade-100">Business date</div>
              <div class="text-sm font-semibold">{{ formatBusinessDate(outlet.businessDate) }}</div>
            </div>
          </template>
          <RouterLink v-else :to="{ name: 'context' }" class="text-sm font-semibold underline underline-offset-4">
            Pilih outlet & terminal
          </RouterLink>
        </div>

        <div class="flex shrink-0 items-center gap-2 px-3">
          <div class="hidden text-right xl:block">
            <div class="text-sm font-semibold">{{ session.me?.user.displayName }}</div>
            <div class="max-w-[16rem] truncate text-xs text-jade-100">{{ session.roleSummary.join(', ') }}</div>
          </div>
          <Button
            v-if="outlet"
            icon="pi pi-sync"
            text
            rounded
            class="!text-white"
            aria-label="Ganti outlet atau terminal"
            v-tooltip.bottom="'Ganti outlet / terminal'"
            @click="router.push({ name: 'context' })"
          />
          <Button icon="pi pi-sign-out" text rounded class="!text-white" aria-label="Keluar" v-tooltip.bottom="'Keluar'" @click="logout" />
        </div>
      </div>
    </header>

    <div class="flex">
      <nav
        id="side-nav"
        :class="[
          'fixed inset-y-0 left-0 z-20 w-60 shrink-0 border-r border-line bg-surface pt-16 transition-transform lg:sticky lg:top-[57px] lg:h-[calc(100vh-57px)] lg:translate-x-0 lg:pt-0',
          navOpen ? 'translate-x-0' : '-translate-x-full',
        ]"
        aria-label="Navigasi utama"
      >
        <ul class="space-y-1 p-3">
          <li>
            <RouterLink :to="{ name: 'home' }" class="nav-link" active-class="nav-link-active" exact-active-class="nav-link-active">
              <i class="pi pi-home" /> Beranda
            </RouterLink>
          </li>
        </ul>
        <template v-if="adminNav.length">
          <p class="px-6 pb-1 pt-4 text-xs font-semibold text-ink-faint">Administrasi</p>
          <ul class="space-y-1 px-3">
            <li v-for="item in adminNav" :key="item.name">
              <RouterLink :to="{ name: item.name }" class="nav-link" active-class="nav-link-active">
                <i :class="item.icon" /> {{ item.label }}
              </RouterLink>
            </li>
          </ul>
        </template>
      </nav>
      <div v-if="navOpen" class="fixed inset-0 z-10 bg-ink/30 lg:hidden" @click="navOpen = false" />

      <main class="min-w-0 flex-1 p-4 sm:p-6 lg:p-8">
        <RouterView />
      </main>
    </div>
  </div>
</template>

<style scoped>
.nav-link {
  @apply flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-ink-soft hover:bg-field hover:text-ink;
}
.nav-link-active {
  @apply bg-jade-50 text-jade-700;
}
</style>
