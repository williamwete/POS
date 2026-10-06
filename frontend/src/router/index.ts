import { createRouter, createWebHistory, type RouteLocationNormalized, type RouteRecordRaw } from 'vue-router'
import { useSessionStore } from '@/stores/session'

type Scope = 'org' | 'any' | 'current'
export interface PermissionRequirement {
  permission: string
  scope: Scope
}

declare module 'vue-router' {
  interface RouteMeta {
    public?: boolean
    /** Halaman kerja kasir: butuh outlet & terminal terpilih. */
    requiresContext?: boolean
    /** Salah satu terpenuhi = boleh. Hanya untuk UX; backend tetap memvalidasi. */
    anyOf?: PermissionRequirement[]
    title?: string
  }
}

export const routes: RouteRecordRaw[] = [
  { path: '/login', name: 'login', component: () => import('@/modules/auth/LoginPage.vue'), meta: { public: true, title: 'Masuk' } },
  {
    path: '/',
    component: () => import('@/layouts/AppLayout.vue'),
    children: [
      { path: '', name: 'home', component: () => import('@/modules/home/HomePage.vue'), meta: { requiresContext: true, title: 'Beranda' } },
      { path: 'attendance/me', name: 'my-attendance', component: () => import('@/modules/attendance/MyAttendancePage.vue'), meta: { title: 'Kehadiran saya' } },
      {
        path: 'attendance/outlet', name: 'outlet-attendance', component: () => import('@/modules/attendance/OutletAttendancePage.vue'),
        meta: { title: 'Kehadiran outlet', anyOf: [{ permission: 'attendance.view', scope: 'any' }] },
      },
      {
        path: 'pos', name: 'pos', component: () => import('@/modules/pos/PosPage.vue'),
        meta: { requiresContext: true, title: 'Kasir', anyOf: [{ permission: 'sale.create', scope: 'current' }] },
      },
      {
        path: 'cashier/open', name: 'cashier-open', component: () => import('@/modules/cashier/OpenCashierPage.vue'),
        meta: { requiresContext: true, title: 'Buka kasir', anyOf: [{ permission: 'cashier.open', scope: 'current' }] },
      },
      {
        path: 'returns', name: 'returns', component: () => import('@/modules/returns/ReturnsPage.vue'),
        meta: {
          title: 'Retur & refund',
          anyOf: [{ permission: 'sale.create', scope: 'current' }, { permission: 'sale.refund', scope: 'any' },
            { permission: 'sale.view', scope: 'any' }],
        },
      },
      {
        // pemilik menutup kasirnya sendiri; supervisor menutup laci kasir lain lewat ?session=<id>
        path: 'cashier/close', name: 'cashier-close', component: () => import('@/modules/cashier/CloseCashierPage.vue'),
        meta: { title: 'Tutup kasir', anyOf: [{ permission: 'cashier.close', scope: 'any' }] },
      },
      {
        path: 'cashier/sessions', name: 'cashier-sessions', component: () => import('@/modules/cashier/OutletCashierPage.vue'),
        meta: { title: 'Sesi kasir', anyOf: [{ permission: 'cashier.view', scope: 'any' }] },
      },
      { path: 'context', name: 'context', component: () => import('@/modules/auth/SelectContextPage.vue'), meta: { title: 'Pilih outlet & terminal' } },
      {
        path: 'admin/outlets', name: 'outlets', component: () => import('@/modules/admin/OutletsPage.vue'),
        meta: { title: 'Outlet', anyOf: [{ permission: 'outlet.manage', scope: 'org' }] },
      },
      {
        path: 'admin/terminals', name: 'terminals', component: () => import('@/modules/admin/TerminalsPage.vue'),
        meta: { title: 'Terminal & device', anyOf: [{ permission: 'terminal.manage', scope: 'any' }] },
      },
      {
        path: 'admin/employees', name: 'employees', component: () => import('@/modules/admin/EmployeesPage.vue'),
        meta: {
          title: 'Karyawan',
          anyOf: [{ permission: 'employee.view', scope: 'any' }, { permission: 'employee.manage', scope: 'any' }],
        },
      },
      {
        path: 'admin/users', name: 'users', component: () => import('@/modules/admin/UsersPage.vue'),
        meta: {
          title: 'User & akses',
          anyOf: [{ permission: 'user.view', scope: 'any' }, { permission: 'user.manage', scope: 'org' }],
        },
      },
      {
        path: 'admin/roles', name: 'roles', component: () => import('@/modules/admin/RolesPage.vue'),
        meta: {
          title: 'Role & permission',
          anyOf: [{ permission: 'role.manage', scope: 'org' }, { permission: 'user.view', scope: 'any' }, { permission: 'user.manage', scope: 'org' }],
        },
      },
      {
        path: 'admin/payment-methods', name: 'payment-methods', component: () => import('@/modules/admin/PaymentMethodsPage.vue'),
        meta: { title: 'Metode pembayaran', anyOf: [{ permission: 'configuration.manage', scope: 'org' }] },
      },
      {
        path: 'admin/sync', name: 'sync', component: () => import('@/modules/admin/SyncPage.vue'),
        meta: { title: 'Sinkronisasi Openbravo', anyOf: [{ permission: 'sync.view', scope: 'any' }, { permission: 'sync.manage', scope: 'org' }] },
      },
      {
        path: 'admin/openbravo-mappings', name: 'openbravo-mappings', component: () => import('@/modules/admin/OpenbravoMappingsPage.vue'),
        meta: { title: 'Pemetaan Openbravo', anyOf: [{ permission: 'configuration.manage', scope: 'org' }] },
      },
      {
        path: 'admin/audit', name: 'audit', component: () => import('@/modules/admin/AuditLogPage.vue'),
        meta: { title: 'Audit log', anyOf: [{ permission: 'audit.view', scope: 'any' }] },
      },
      { path: 'forbidden', name: 'forbidden', component: () => import('@/modules/home/ForbiddenPage.vue'), meta: { title: 'Akses ditolak' } },
    ],
  },
  { path: '/:pathMatch(.*)*', name: 'not-found', component: () => import('@/modules/home/NotFoundPage.vue'), meta: { public: true, title: 'Tidak ditemukan' } },
]

export function guard(to: RouteLocationNormalized) {
  const session = useSessionStore()
  if (to.meta.public) {
    if (to.name === 'login' && session.isAuthenticated) return { name: 'home' }
    return true
  }
  if (!session.isAuthenticated) {
    return { name: 'login', query: to.fullPath !== '/' ? { redirect: to.fullPath } : {} }
  }
  if (to.meta.requiresContext && (!session.outletId || !session.terminal)) {
    return { name: 'context' }
  }
  const reqs = to.meta.anyOf
  if (reqs && !reqs.some((r) => session.can(r.permission, r.scope))) {
    return { name: 'forbidden' }
  }
  return true
}

export function createAppRouter() {
  const router = createRouter({ history: createWebHistory(), routes })
  router.beforeEach(guard)
  router.afterEach((to) => {
    document.title = to.meta.title ? `${to.meta.title} · POS` : 'POS'
  })
  return router
}
