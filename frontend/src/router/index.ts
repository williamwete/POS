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
        path: 'history', name: 'history', component: () => import('@/modules/pos/HistoryPage.vue'),
        meta: { requiresContext: true, title: 'History', anyOf: [{ permission: 'sale.create', scope: 'current' }] },
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
        meta: { title: 'Outlet', anyOf: [{ permission: 'platform.manage', scope: 'org' }] },
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
          anyOf: [{ permission: 'platform.manage', scope: 'org' }],
        },
      },
      {
        path: 'admin/payment-methods', name: 'payment-methods', component: () => import('@/modules/admin/PaymentMethodsPage.vue'),
        meta: { title: 'Metode pembayaran', anyOf: [{ permission: 'configuration.manage', scope: 'org' }] },
      },
      {
        path: 'admin/sync', name: 'sync', component: () => import('@/modules/admin/SyncPage.vue'),
        meta: { title: 'Sinkronisasi Openbravo', anyOf: [{ permission: 'platform.manage', scope: 'org' }] },
      },
      {
        path: 'admin/openbravo-mappings', name: 'openbravo-mappings', component: () => import('@/modules/admin/OpenbravoMappingsPage.vue'),
        meta: { title: 'Pemetaan Openbravo', anyOf: [{ permission: 'platform.manage', scope: 'org' }] },
      },
      {
        path: 'admin/audit', name: 'audit', component: () => import('@/modules/admin/AuditLogPage.vue'),
        meta: { title: 'Audit log', anyOf: [{ permission: 'audit.view', scope: 'any' }] },
      },
      {
        path: 'catalog/products', name: 'product-list', component: () => import('@/modules/catalog/ProductListPage.vue'),
        meta: { title: 'Product List', anyOf: [{ permission: 'stock.view', scope: 'current' }, { permission: 'product.manage', scope: 'any' }] },
      },
      {
        path: 'manage/categories', name: 'manage-categories', component: () => import('@/modules/catalog/CategoriesPage.vue'),
        meta: { title: 'Manage Categories', anyOf: [{ permission: 'category.manage', scope: 'org' }] },
      },
      {
        path: 'manage/discount', name: 'manage-discount', component: () => import('@/modules/catalog/DiscountsPage.vue'),
        meta: { title: 'Manage Discount', anyOf: [{ permission: 'discount.manage', scope: 'any' }] },
      },
      {
        path: 'manage/receipt', name: 'manage-receipt', component: () => import('@/modules/catalog/ReceiptSettingsPage.vue'),
        meta: { title: 'Manage Receipt', anyOf: [{ permission: 'receipt.manage', scope: 'any' }] },
      },
      {
        path: 'manage/cashier', name: 'manage-cashier', component: () => import('@/modules/admin/EmployeesPage.vue'),
        meta: { title: 'Manage Cashier', anyOf: [{ permission: 'employee.view', scope: 'any' }, { permission: 'employee.manage', scope: 'any' }] },
      },
      {
        path: 'admin/menu-access', name: 'menu-access', component: () => import('@/modules/admin/MenuAccessPage.vue'),
        meta: { title: 'Akses menu', anyOf: [{ permission: 'menu.configure', scope: 'org' }] },
      },
      {
        path: 'platform', name: 'platform', component: () => import('@/modules/platform/PlatformPage.vue'),
        meta: { title: 'Merchant', anyOf: [{ permission: 'platform.manage', scope: 'org' }] },
      },
      {
        path: 'settings', name: 'settings', component: () => import('@/modules/admin/SettingsPage.vue'),
        meta: { title: 'Pengaturan', anyOf: [{ permission: 'configuration.manage', scope: 'org' }] },
      },
      {
        path: 'offline-reviews', name: 'offline-reviews', component: () => import('@/modules/report/OfflineReviewsPage.vue'),
        meta: { title: 'Transaksi offline', anyOf: [{ permission: 'report.view', scope: 'any' }] },
      },
      {
        path: 'dashboard', name: 'dashboard', component: () => import('@/modules/report/DashboardPage.vue'),
        meta: { title: 'Dashboard', anyOf: [{ permission: 'report.view', scope: 'any' }] },
      },
      {
        path: 'finance', name: 'finance', component: () => import('@/modules/finance/FinancePage.vue'),
        meta: { title: 'Saldo & pencairan', anyOf: [{ permission: 'finance.manage', scope: 'org' }] },
      },
      {
        path: 'platform/payouts', name: 'platform-payouts', component: () => import('@/modules/platform/PayoutsPage.vue'),
        meta: { title: 'Pencairan', anyOf: [{ permission: 'platform.manage', scope: 'org' }] },
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
  // Operator platform tidak punya outlet: beranda-nya adalah daftar merchant.
  if (to.name === 'home' && session.can('platform.manage', 'org')) {
    return { name: 'platform' }
  }
  if (to.meta.requiresContext && (!session.outletId || !session.terminal)) {
    return { name: 'context' }
  }
  // Alur Figma: halaman awal kasir adalah katalog penjualan.
  if (to.name === 'home' && session.me?.employee && session.can('sale.create', 'current')) {
    return { name: 'pos' }
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
