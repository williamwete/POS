// Kontrak API — cerminan DTO backend (backend/src/main/java/.../*Dtos.java)

export interface ApiFieldError {
  field: string | null
  message: string
}

export interface ApiEnvelope<T> {
  success: boolean
  data?: T
  message?: string
  errorCode?: string
  details?: ApiFieldError[]
  requestId?: string
}

export interface PageResult<T> {
  items: T[]
  page: number
  size: number
  total: number
}

export interface MeResponse {
  user: { id: string; username: string; email: string; displayName: string; lastLoginAt?: string }
  employee?: { id: string; employeeCode: string; fullName: string; position?: string; homeOutletId?: string }
  organization: { id: string; code: string; name: string; timezone: string; currency: string }
  roles: RoleAssignment[]
  organizationPermissions: string[]
  outlets: OutletAccess[]
}

export interface RoleAssignment {
  roleId: string
  roleCode: string
  roleName: string
  outletId?: string
  outletCode?: string
}

export interface OutletAccess {
  id: string
  code: string
  name: string
  timezone: string
  active: boolean
  businessDate: string
  permissions: string[]
}

export interface Outlet {
  id: string
  organizationId: string
  code: string
  name: string
  address?: string
  phone?: string
  timezone?: string
  defaultWarehouseId?: string
  active: boolean
  version: number
  createdAt: string
  updatedAt: string
}

export interface Warehouse {
  id: string
  organizationId: string
  outletId?: string
  code: string
  name: string
  active: boolean
  version: number
}

export type DeviceType = 'BROWSER' | 'PRINTER' | 'CASH_DRAWER' | 'SCANNER' | 'CUSTOMER_DISPLAY'

export interface Device {
  id: string
  outletId: string
  deviceType: DeviceType
  code: string
  name: string
  identifier?: string
  active: boolean
  lastSeenAt?: string
  version: number
}

export interface Terminal {
  id: string
  outletId: string
  outletCode: string
  code: string
  name: string
  deviceId?: string
  printerId?: string
  printerName?: string
  cashDrawerId?: string
  cashDrawerName?: string
  active: boolean
  version: number
  updatedAt: string
}

export interface Employee {
  id: string
  organizationId: string
  employeeCode: string
  fullName: string
  phone?: string
  email?: string
  position?: string
  homeOutletId?: string
  homeOutletCode?: string
  hireDate?: string
  active: boolean
  linkedUserId?: string
  linkedUsername?: string
  version: number
  updatedAt: string
}

export interface RoleGrant {
  roleId: string
  roleCode: string
  roleName: string
  rank: number
  outletId?: string
  outletCode?: string
}

export interface UserAccount {
  id: string
  username: string
  email: string
  displayName: string
  employeeId?: string
  employeeCode?: string
  employeeName?: string
  active: boolean
  lastLoginAt?: string
  version: number
  roles: RoleGrant[]
  outlets: { outletId: string; outletCode: string; outletName: string }[]
}

export interface Role {
  id: string
  code: string
  name: string
  description?: string
  system: boolean
  rank: number
  permissions: string[]
}

export interface Permission {
  code: string
  module: string
  description: string
}

export interface AuditLog {
  id: string
  seq: number
  actorType: 'USER' | 'SYSTEM'
  actorUserId?: string
  actorUsername?: string
  action: string
  entityType: string
  entityId?: string
  outletId?: string
  terminalId?: string
  oldValue?: unknown
  newValue?: unknown
  reason?: string
  ipAddress?: string
  deviceId?: string
  requestId?: string
  createdAt: string
}

export type AttendanceStatus = 'WORKING' | 'ON_BREAK' | 'COMPLETED' | 'FORCED_CLOSED'

export interface AttendanceBreak {
  id: string
  breakStart: string
  breakEnd?: string
  durationSeconds?: number
  reason?: string
}

export interface Attendance {
  id: string
  employeeId: string
  employeeCode: string
  employeeName: string
  outletId: string
  outletCode: string
  businessDate: string
  clockIn: string
  clockOut?: string
  status: AttendanceStatus
  deviceId?: string
  forcedReason?: string
  clockOutByUsername?: string
  breakSeconds: number
  version: number
  breaks: AttendanceBreak[]
}

export type CashierSessionStatus = 'OPEN' | 'ON_BREAK' | 'CLOSING' | 'CLOSED' | 'CANCELLED'
export type LockReason = 'MANUAL' | 'IDLE' | 'BREAK' | 'FORCED_CLOCK_OUT'

export interface Denomination {
  id: string
  currency: string
  value: number
  kind: 'NOTE' | 'COIN'
  sortOrder: number
}

export interface CashCountItem {
  value: number
  kind: 'NOTE' | 'COIN'
  quantity: number
  subtotal: number
}

export interface CashCount {
  id: string
  countType: 'OPENING' | 'MID' | 'CLOSING' | 'HANDOVER'
  totalAmount: number
  /** null untuk kasir (blind count); terisi untuk pemegang cashier.view */
  expectedAmount?: number | null
  difference?: number | null
  note?: string
  countedAt: string
  countedByUsername?: string
  items: CashCountItem[]
}

export interface CashierSession {
  id: string
  employeeId: string
  employeeCode: string
  employeeName: string
  outletId: string
  outletCode: string
  terminalId: string
  terminalCode: string
  terminalName: string
  businessDate: string
  openedAt: string
  closedAt?: string
  openingCash: number
  expectedCash?: number | null
  status: CashierSessionStatus
  lockedAt?: string
  lockReason?: LockReason
  cancelReason?: string
  version: number
  idleLockMinutes: number
  counts: CashCount[]
}

/** Baris hitungan yang dikirim ke server: nilai uang selalu dihitung ulang server. */
export interface CountLine {
  denominationId: string
  quantity: number
}
