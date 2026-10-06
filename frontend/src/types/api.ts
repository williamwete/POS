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
  // hasil tutup kasir (hanya bila CLOSED)
  closingCash?: number | null
  difference?: number | null
  differenceReason?: DifferenceReason | null
  differenceNote?: string | null
  closedByName?: string | null
  differenceApprovedByName?: string | null
  counts: CashCount[]
}

export type CashMovementType =
  | 'OPENING_CASH' | 'CASH_SALE' | 'CASH_SALE_REVERSAL' | 'CASH_IN' | 'CASH_OUT' | 'PETTY_CASH'
  | 'CASH_REFUND' | 'CASH_ADJUSTMENT' | 'CLOSING_CASH'

export interface CashMovement {
  id: string
  movementType: CashMovementType
  /** bertanda: + masuk laci, − keluar laci */
  amount: number
  reason?: string | null
  referenceType?: string | null
  createdAt: string
  createdByName?: string | null
  approvedByName?: string | null
}

export type DifferenceReason = 'SHORTAGE' | 'OVERAGE' | 'WRONG_CHANGE' | 'COUNTING_ERROR' | 'OTHER'

export interface ClosePreview {
  countedCash: number
  expectedCash: number
  difference: number
  approvalThreshold: number
  reasonRequired: boolean
  approvalRequired: boolean
  openOrders: number
  pendingPayments: number
  allowCloseWithOpenOrders: boolean
}

export interface CloseRequest {
  counts: CountLine[]
  differenceReason?: DifferenceReason | null
  differenceNote?: string | null
  approvalId?: string | null
  note?: string | null
}

export type CashApprovalAction = 'CASH_OUT' | 'CASH_DIFFERENCE'

export interface CashApprovalResult {
  id: string
  action: CashApprovalAction
  approverName: string
  amount: number
  expiresAt?: string
}

/** Baris hitungan yang dikirim ke server: nilai uang selalu dihitung ulang server. */
export interface CountLine {
  denominationId: string
  quantity: number
}

export interface Product {
  id: string
  sku: string
  name: string
  categoryId?: string
  categoryName?: string
  imageUrl?: string
  uom: string
  allowDecimalQty: boolean
  barcode?: string
  price?: number
  priceVersion?: number
  taxRate: number
  /** null/undefined = stok tidak diketahui */
  available?: number | null
  allowNegativeStock: boolean
}

export interface ProductCategory {
  id: string
  code: string
  name: string
  productCount: number
}

export type SaleStatus = 'DRAFT' | 'HELD' | 'CHECKOUT' | 'PAYMENT_PENDING' | 'PAID' | 'POSTING' | 'POSTED'
  | 'VOID' | 'RETURNED' | 'CANCELLED'

export interface SaleItem {
  id: string
  lineNo: number
  productId: string
  sku: string
  productName: string
  barcode?: string
  uom: string
  quantity: number
  listPrice: number
  unitPrice: number
  priceOverrideReason?: string
  taxRate: number
  grossAmount: number
  itemDiscountAmount: number
  cartDiscountAmount: number
  netAmount: number
  taxAmount: number
  status: 'ACTIVE' | 'VOID'
  voidReason?: string
}

export interface SaleDiscount {
  id: string
  saleItemId?: string
  discountType: 'PERCENTAGE' | 'AMOUNT'
  discountValue: number
  amount: number
  reason: string
  approvedByUsername?: string
  status: 'ACTIVE' | 'REMOVED'
}

export interface Sale {
  id: string
  clientTransactionId: string
  receiptNo?: string
  status: SaleStatus
  syncStatus: string
  outletId: string
  outletCode: string
  terminalId: string
  terminalCode: string
  cashierSessionId: string
  employeeId: string
  employeeName: string
  businessDate: string
  pricesIncludeTax: boolean
  lineCount: number
  itemCount: number
  subtotal: number
  itemDiscountTotal: number
  cartDiscountTotal: number
  discountTotal: number
  taxTotal: number
  grandTotal: number
  paidAmount: number
  changeAmount: number
  paidAt?: string
  note?: string
  heldAt?: string
  checkedOutAt?: string
  voidedAt?: string
  voidReason?: string
  createdAt: string
  version: number
  items: SaleItem[]
  discounts: SaleDiscount[]
}

export type ApprovalAction = 'DISCOUNT' | 'PRICE_OVERRIDE' | 'VOID_SALE' | 'PAYMENT_CONFIRM'

export interface ApprovalPayload {
  action: ApprovalAction
  saleId: string
  saleItemId?: string
  discountType?: 'PERCENTAGE' | 'AMOUNT'
  discountValue?: number
  price?: number
}

export interface ApprovalResult {
  id: string
  action: ApprovalAction
  approverName: string
  maxPercent?: number
  expiresAt: string
}

export interface ReceiptLine {
  name: string
  sku: string
  quantity: number
  uom: string
  unitPrice: number
  listPrice: number
  discount: number
  amount: number
  taxRate: number
}

export interface Receipt {
  saleId: string
  receiptNo: string
  status: SaleStatus
  organizationName: string
  outletName: string
  outletAddress?: string
  outletPhone?: string
  terminalCode: string
  cashierName: string
  businessDate: string
  issuedAt?: string
  pricesIncludeTax: boolean
  lines: ReceiptLine[]
  itemCount: number
  subtotal: number
  discountTotal: number
  taxTotal: number
  grandTotal: number
  payments: ReceiptPayment[]
  paidAmount: number
  changeAmount: number
  paidAt?: string
  printCount: number
}

export interface ReceiptPayment {
  methodName: string
  methodKind: string
  amount: number
  amountReceived: number
  changeAmount: number
  referenceNumber?: string
}

export type PaymentConfirmation = 'IMMEDIATE' | 'MANUAL' | 'GATEWAY'
export type PaymentStatus = 'PENDING' | 'PAID' | 'FAILED' | 'CANCELLED' | 'REFUNDED'

export interface PaymentMethod {
  id: string
  code: string
  name: string
  kind: 'CASH' | 'CARD' | 'QRIS' | 'EWALLET' | 'TRANSFER' | 'OTHER'
  confirmation: PaymentConfirmation
  requiresReference: boolean
  requiresApproval: boolean
  manualConfirmAllowed: boolean
  active: boolean
  sortOrder: number
  openbravoPaymentMethodId?: string
  version: number
  available: boolean
}

export interface Payment {
  id: string
  saleId: string
  methodCode: string
  methodName: string
  methodKind: string
  confirmation: PaymentConfirmation
  amount: number
  amountReceived: number
  changeAmount: number
  status: PaymentStatus
  referenceNumber?: string
  provider?: string
  externalTransactionId?: string
  qrPayload?: string
  expiresAt?: string
  paidAt?: string
  failedReason?: string
  cancelReason?: string
  approvedByUsername?: string
  manualConfirmAllowed: boolean
  createdAt: string
  version: number
}

export interface PaymentResult {
  payment: Payment
  sale: Sale
  simulated: boolean
}
