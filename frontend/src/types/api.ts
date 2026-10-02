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
