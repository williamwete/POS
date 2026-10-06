# API — Phase 1

Semua endpoint `/api/**` memerlukan header `Authorization: Bearer <JWT Supabase>`, kecuali
`POST /api/dev-auth/token` (hanya ada pada profile `local`/`test`).

Header opsional: `X-Request-Id` (dikembalikan di response), `X-Device-Id`, `X-Terminal-Id`,
`X-Outlet-Id` (untuk jejak audit, **bukan** otorisasi), `Idempotency-Key` (8–128 karakter
`[A-Za-z0-9._:-]`, didukung pada semua POST pembuat data).

Response sukses / error:
```json
{ "success": true, "data": {}, "message": "Outlet dibuat", "requestId": "..." }
{ "success": false, "errorCode": "OUTLET_ACCESS_DENIED", "message": "...", "details": [], "requestId": "..." }
```
Response replay idempotency membawa header `Idempotent-Replayed: true`.

| Method | Path | Permission | Keterangan |
|---|---|---|---|
| POST | `/api/dev-auth/token` | publik, local only | `{email,password}` → JWT berbentuk Supabase |
| GET | `/api/auth/me` | login | profil, employee, organisasi, role, permission per outlet, business date |
| POST | `/api/auth/session` | login | panggil setelah login: audit `LOGIN`, `last_login_at` |
| POST | `/api/auth/logout` | login | audit `LOGOUT` |
| GET | `/api/outlets` | login | outlet yang dapat diakses |
| GET | `/api/outlets/{id}` | akses outlet | |
| POST | `/api/outlets` | `outlet.manage` (org) | idempotent |
| PUT | `/api/outlets/{id}` | `outlet.manage` (org) | optimistic lock `version` |
| GET | `/api/warehouses?outletId=` | login / akses outlet | |
| POST | `/api/warehouses` | `outlet.manage` (org) | idempotent |
| GET | `/api/terminals?outletId=` | akses outlet | |
| GET | `/api/terminals/{id}` | akses outlet | |
| POST | `/api/terminals` | `terminal.manage` @outlet | idempotent; device harus satu outlet & tipe benar |
| PUT | `/api/terminals/{id}` | `terminal.manage` @outlet | `version` |
| GET | `/api/devices?outletId=` | akses outlet | |
| POST | `/api/devices` | `terminal.manage` @outlet | idempotent |
| PUT | `/api/devices/{id}` | `terminal.manage` @outlet | tidak bisa dinonaktifkan jika terpasang di terminal aktif |
| GET | `/api/employees?outletId=&q=&active=&limit=` | RLS (`employee.view`/`manage`) | |
| GET | `/api/employees/{id}` | RLS | |
| POST | `/api/employees` | `employee.manage` @home outlet (org jika tanpa outlet) | idempotent |
| PUT | `/api/employees/{id}` | `employee.manage` @outlet lama & baru | tolak nonaktif jika akun login masih aktif |
| GET | `/api/users?q=&active=` | RLS (`user.view`/`user.manage`) | |
| GET | `/api/users/{id}` | RLS | termasuk role & outlet |
| POST | `/api/users` | `user.manage` (org) + rank | idempotent; membuat akun Supabase Auth |
| PUT | `/api/users/{id}` | `user.manage` + rank, bukan diri sendiri | nonaktif → login diblokir di Supabase |
| PUT | `/api/users/{id}/roles` | `user.manage` + rank | ganti seluruh set role (diff + audit) |
| PUT | `/api/users/{id}/outlets` | `user.manage` + rank | ganti seluruh set akses outlet |
| POST | `/api/users/{id}/reset-password` | `user.manage` + rank | password tidak masuk audit |
| GET | `/api/roles` | login | role + permission |
| GET | `/api/permissions` | login | katalog |
| PUT | `/api/roles/{id}/permissions` | `role.manage` (org) + rank | hanya permission yang dipegang sendiri |
| GET | `/api/audit-logs?action=&entityType=&entityId=&outletId=&actorUserId=&from=&to=&page=&size=` | `audit.view` | org-wide, atau outlet tertentu |
| GET | `/api/attendance/current` | login | kehadiran terbuka milik sendiri (null jika belum clock in) |
| POST | `/api/attendance/clock-in` | `attendance.clock_in` @outlet | `{outletId}`; idempotent; waktu dari server |
| POST | `/api/attendance/break/start` | kehadiran sendiri WORKING | `{reason?}`; setting `break_enabled` |
| POST | `/api/attendance/break/end` | kehadiran sendiri ON_BREAK | |
| POST | `/api/attendance/clock-out` | `attendance.clock_out` @outlet | ditolak jika masih istirahat |
| POST | `/api/attendance/{id}/force-clock-out` | `attendance.force_clock_out` @outlet, bukan diri sendiri | `{reason}` min 5 karakter; menutup break yang berjalan |
| GET | `/api/attendance/history?from=&to=` | login (karyawan) | riwayat sendiri, maks 1 tahun |
| GET | `/api/attendance?outletId=&businessDate=&status=` | `attendance.view` @outlet | default business date hari ini |

### Cashier session (Phase 3)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/cashier/denominations` | login | pecahan uang aktif organisasi |
| GET | `/api/cashier/sessions/current` | login | session aktif milik sendiri (null jika belum buka kasir) |
| POST | `/api/cashier/sessions/open` | `cashier.open` @outlet terminal | `{terminalId, counts:[{denominationId, quantity}], note?}`; wajib WORKING di outlet yang sama; modal awal = jumlah hitungan (dihitung server); idempotent |
| POST | `/api/cashier/sessions/{id}/cash-count` | pemilik, session OPEN | hitung kas tengah shift (blind count); idempotent |
| POST | `/api/cashier/sessions/{id}/lock` | pemilik | `{reason: MANUAL\|IDLE}`; status `ON_BREAK` |
| POST | `/api/cashier/sessions/{id}/unlock` | pemilik | wajib token hasil **login ulang** setelah waktu kunci (`REAUTH_REQUIRED`), dan sedang WORKING |
| POST | `/api/cashier/sessions/{id}/cancel` | pemilik | `{reason}` min 5 karakter; hanya bila belum ada aktivitas kas |
| GET | `/api/cashier/sessions/{id}` | pemilik atau `cashier.view` @outlet | detail + hitungan + rincian pecahan |
| GET | `/api/cashier/sessions?outletId=&businessDate=&status=` | `cashier.view` @outlet | session business date tsb + yang masih aktif |

Expected cash dan selisih hitungan hanya dikirim kepada pemegang `cashier.view` (kasir: `null`).

Error baru: `ATTENDANCE_REQUIRED`, `TERMINAL_ALREADY_OPEN`, `TERMINAL_MISMATCH`, `TERMINAL_INACTIVE`,
`CASHIER_SESSION_ALREADY_OPEN`, `CASHIER_SESSION_OPEN` (clock out ditolak), `CASHIER_SESSION_LOCKED`,
`CASHIER_SESSION_NOT_LOCKED`, `CASHIER_SESSION_CLOSED`, `CASHIER_SESSION_HAS_ACTIVITY`, `REAUTH_REQUIRED`,
`DENOMINATION_INVALID`, `OPENING_CASH_MISMATCH`.
| GET | `/api/settings/effective?outletId=` | login / akses outlet | konfigurasi efektif §73 |
| GET | `/actuator/health/liveness`, `/readiness` | publik | probe |

Kode error: lihat `backend/.../common/error/ErrorCode.java`; pesan human readable di
`frontend/src/utils/errorMessages.ts`.

### Produk & penjualan (Phase 4)

Semua `/api/sales/*` hanya untuk pemegang cashier session **OPEN** (tidak terkunci) yang sedang WORKING.
Harga, pajak, total, dan nomor struk dihitung database; client hanya mengirim produk, jumlah, dan definisi diskon.

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/products?outletId=&q=&categoryId=&limit=` | login, akses outlet | katalog/cari nama/SKU/barcode; harga berlaku, stok tersedia outlet, foto (`imageUrl`); `limit` maks 200 |
| GET | `/api/product-categories` | login | kategori yang punya produk aktif + jumlah produk (tab katalog) |
| GET | `/api/products/barcode/{barcode}?outletId=` | login, akses outlet | produk untuk satu barcode |
| GET | `/api/sales/current` | login | transaksi aktif (DRAFT/CHECKOUT) di session sendiri |
| GET | `/api/sales/held` | login | transaksi yang ditahan di session sendiri |
| GET | `/api/sales?outletId=&businessDate=` | `sale.view` @outlet | daftar transaksi outlet |
| POST | `/api/sales` | `sale.create` @outlet session | `{clientTransactionId, note?}`; satu DRAFT per session; `clientTransactionId` unik (anti duplikat) |
| GET | `/api/sales/{id}` | pemilik atau `sale.view` | detail + baris + diskon |
| POST | `/api/sales/{id}/items` | pemilik, DRAFT | `{productId \| barcode, quantity}`; produk sama digabung |
| POST | `/api/sales/{id}/items/{itemId}/quantity` | pemilik, DRAFT | `{quantity}`; desimal hanya untuk produk timbangan |
| POST | `/api/sales/{id}/items/{itemId}/void` | pemilik, DRAFT | `{reason}`; baris tidak dihapus |
| POST | `/api/sales/{id}/items/{itemId}/price` | pemilik, DRAFT | `{unitPrice, reason, approvalId?}`; approval sesuai `require_supervisor_for_price_override` |
| POST | `/api/sales/{id}/discounts` | `sale.discount` | `{saleItemId?, type: PERCENTAGE\|AMOUNT, value, reason, approvalId?}`; tanpa `saleItemId` = diskon transaksi |
| POST | `/api/sales/{id}/discounts/{discountId}/remove` | pemilik, DRAFT | |
| POST | `/api/sales/{id}/hold` · `/resume` | pemilik | tahan / lanjutkan (§26) |
| POST | `/api/sales/{id}/checkout` | pemilik | validasi diskon, approval & stok; alokasi nomor struk |
| POST | `/api/sales/{id}/reopen` | pemilik, CHECKOUT | kembali ke keranjang sebelum pembayaran; nomor struk tetap |
| POST | `/api/sales/{id}/cancel` | pemilik | hanya keranjang kosong |
| POST | `/api/sales/{id}/void` | pemilik; approval bila sudah checkout | `{reason, approvalId?}` |
| GET | `/api/sales/{id}/receipt` | pemilik atau `sale.view` | data struk 80 mm |
| POST | `/api/sales/{id}/receipt/print` | pemilik atau `sale.view` | catat cetak / cetak ulang (print count) |
| POST | `/api/approvals` | approver: izin & rank sesuai aksi | `{action: DISCOUNT\|PRICE_OVERRIDE\|VOID_SALE, saleId, saleItemId?, discountType?, discountValue?, price?, email, password}`; rate limit ketat; approval sekali pakai, berlaku 2 menit |

Semua POST di atas (kecuali `/api/approvals`) idempotent dengan `Idempotency-Key`.

Error baru: `CASHIER_SESSION_REQUIRED`, `SALE_NOT_FOUND`, `SALE_NOT_EDITABLE`, `SALE_CLOSED`, `SALE_EMPTY`,
`SALE_NOT_EMPTY`, `PRODUCT_NOT_FOUND`, `PRODUCT_NOT_AVAILABLE`, `PRICE_NOT_FOUND`, `QUANTITY_INVALID`,
`STOCK_UNAVAILABLE`, `APPROVAL_REQUIRED`, `APPROVER_INVALID`, `APPROVER_NOT_AUTHORIZED`, `APPROVAL_EXPIRED`,
`DISCOUNT_LIMIT_EXCEEDED`, `DISCOUNT_INVALID`, `RECEIPT_NOT_AVAILABLE`.

### Pembayaran (Phase 5)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/payment-methods` | login | metode aktif; `available=false` bila metode gateway belum punya penyedia & tidak boleh konfirmasi manual |
| GET | `/api/sales/{id}/payments` | pemilik atau `sale.view` | semua pembayaran transaksi |
| POST | `/api/sales/{id}/payments` | pemilik, sale CHECKOUT/PAYMENT_PENDING | `{clientPaymentId, methodCode, amountReceived (tunai) \| amount (non-tunai), referenceNumber?, approvalId?}`; respons `{payment, sale, simulated}`; `clientPaymentId` sama = pembayaran yang sama |
| GET | `/api/payments/{id}` | pemilik atau `sale.view` | status terbaru; untuk gateway PENDING server menanyakan penyedia (polling) |
| POST | `/api/payments/{id}/cancel` | pemilik | `{reason}`; PENDING → batal; PAID tunai/manual sebelum lunas → pembalikan (cash movement `CASH_SALE_REVERSAL`) |
| POST | `/api/payments/{id}/confirm` | pemilik + approval `PAYMENT_CONFIRM` | `{referenceNumber, approvalId}`; hanya metode gateway yang diizinkan konfirmasi manual (QRIS statis) |
| POST | `/api/payments/callback/{provider}` | **publik**, HMAC | header `X-POS-Signature` = hex(HMAC-SHA256(secret, timestamp + "." + body)), `X-POS-Timestamp` (epoch detik, ±5 menit); body `{externalTransactionId, status: PAID\|FAILED\|EXPIRED, amount, reference}`; idempoten |
| POST | `/api/dev-payments/{id}/simulate` | login, **hanya profile local/test** | `{result: PAID\|FAILED}`; mengirim callback bertanda tangan dari simulator |
| GET | `/api/admin/payment-methods` | `configuration.manage` org | semua metode |
| PUT | `/api/admin/payment-methods/{id}` | `configuration.manage` org | `{name, active, requiresReference, requiresApproval, manualConfirmAllowed, sortOrder, openbravoPaymentMethodId?, version}`; tunai tidak bisa dinonaktifkan |

Approval `POST /api/approvals` mendapat aksi `PAYMENT_CONFIRM` (`price` = jumlah pembayaran; approver perlu `payment.approve`).

Error baru: `SALE_NOT_PAYABLE`, `SALE_ALREADY_PAID`, `SALE_NOT_FULLY_PAID`, `SALE_HAS_PAYMENTS`, `PAYMENT_NOT_FOUND`,
`PAYMENT_METHOD_INVALID`, `PAYMENT_AMOUNT_INVALID`, `PAYMENT_EXCEEDS_REMAINING`, `PAYMENT_REFERENCE_REQUIRED`,
`PAYMENT_CONFIRMATION_REQUIRED`, `PAYMENT_NOT_REVERSIBLE`, `PAYMENT_CANCEL_REASON_REQUIRED`, `PAYMENT_INVALID_TRANSITION`,
`PAYMENT_GATEWAY_UNAVAILABLE`, `PAYMENT_CALLBACK_INVALID`.

### Manajemen kas & tutup kasir (Phase 6)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/cashier/sessions/{id}/movements` | pemilik atau `cashier.view` @outlet | mutasi kas; pemilik **tidak** melihat baris penjualan tunai (blind count) |
| POST | `/api/cashier/sessions/{id}/cash-movements` | pemilik, session OPEN, `cash.cash_in`/`cash.cash_out` | `{type: CASH_IN\|CASH_OUT\|PETTY_CASH, amount (>0, rupiah bulat), reason (≥3), approvalId?}`; kas keluar > `cash_out_approval_threshold` wajib approval `CASH_OUT` dengan nominal sama; tidak boleh melebihi isi laci (`CASH_INSUFFICIENT`); idempotent |
| POST | `/api/cashier/sessions/{id}/adjustments` | `cash.cash_adjustment` @outlet, **bukan laci sendiri** | `{amount (bertanda, ≠0), reason (≥5)}`; tercatat atas nama atasan; idempotent |
| POST | `/api/cashier/sessions/{id}/close/preview` | pemilik (`cashier.close`) atau atasan (`cashier.close` + `cash.approve_difference`) | `{counts}` → `{countedCash, expectedCash, difference, approvalThreshold, reasonRequired, approvalRequired, openOrders, pendingPayments, pendingReturns, allowCloseWithOpenOrders}`; tidak menulis data kas, dicatat di audit (`CLOSE_PREVIEW`) |
| POST | `/api/cashier/sessions/{id}/close` | sama dengan preview | `{counts, differenceReason?: SHORTAGE\|OVERAGE\|WRONG_CHANGE\|COUNTING_ERROR\|OTHER, differenceNote?, approvalId?, note?}`; expected & selisih dihitung database; respons session `CLOSED` dengan `closingCash`, `expectedCash`, `difference`, `closedByName`, `differenceApprovedByName`; idempotent |
| POST | `/api/cashier/approvals` | pemilik session (atau atasan yang menutup laci lain, khusus `CASH_DIFFERENCE`); **rate limit seperti login** | `{action: CASH_OUT\|CASH_DIFFERENCE, sessionId, amount, email, password}` → approval sekali pakai 2 menit; approver perlu `cash.approve_difference` & rank ≥ SUPERVISOR, bukan peminta |

Session `CLOSED` menampilkan `expectedCash` hasil penutupan kepada pemilik juga; selama session aktif expected cash
tetap hanya untuk `cashier.view`.

Error baru: `OPEN_ORDER_EXISTS` (tutup kasir), `PAYMENT_PENDING`, `CLOSING_COUNT_REQUIRED`,
`CASH_DIFFERENCE_REASON_REQUIRED`, `CASH_DIFFERENCE_REQUIRES_APPROVAL`, `CASH_INSUFFICIENT`, `CASH_MOVEMENT_REASON_REQUIRED`.

### Laporan closing (Phase 7)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| POST | `/api/cashier/sessions/{id}/x-report` | `cashier.view` @outlet | X report tengah shift (session OPEN/ON_BREAK); tidak mengubah session; dicatat audit `X_REPORT` |
| GET | `/api/cashier/sessions/{id}/z-report` | pemilik atau `cashier.view` | cash-up yang dibuat saat tutup kasir: `{reportType: Z, zNumber, cashupId, header, sales, payments[], cash, approval, generatedAt}`; `CASHUP_NOT_FOUND` bila belum ditutup |
| POST | `/api/cashier/sessions/{id}/z-report/print` | pemilik atau `cashier.view` | catat cetak/cetak ulang Z (`Z_REPORT_PRINT`) |
| GET | `/api/cashier/sessions/{id}/transactions` | `cashier.view`, atau pemilik setelah CLOSED | §54 detail transaksi: no struk, waktu, status, jumlah item, total, metode bayar, alasan void |

Struktur laporan X dan Z sama (dihitung `pos.compute_shift_report`); X tidak berisi `actualCash`/`difference`.
Error baru: `CASHUP_NOT_FOUND`.

### Retur & refund (Phase 8)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/returns/lookup?receiptNo=` | `sale.create` atau `sale.refund` @outlet struk | data struk untuk retur: baris (terjual, sudah diretur, sisa jumlah & nilai), pembayaran (dibayar, sudah direfund), retur sebelumnya |
| POST | `/api/returns` | `sale.create`, kasir dengan session OPEN di outlet struk | `{clientReturnId, originalSaleId, reason, refundMode: CASH\|ORIGINAL, refundReference?, items:[{saleItemId, quantity, returnToStock?}]}` → retur `PENDING_APPROVAL` (nomor `RET-<terminal>-<YYYYMMDD>-<urut>`, nilai dari database); `clientReturnId` sama = retur yang sama; idempotent |
| GET | `/api/returns/{id}` | pembuat, `sale.view` atau `sale.refund` | retur + baris + refund |
| GET | `/api/returns?outletId=&businessDate=&status=` | `sale.view` atau `sale.refund` @outlet | retur business date tsb + yang masih menunggu |
| POST | `/api/returns/{id}/approve-at-terminal` | pembuat; **rate limit seperti login** | `{email, password, refundReference?}` approver (izin `sale.refund`, rank ≥ SUPERVISOR, bukan pembuat) → `COMPLETED` + refund |
| POST | `/api/returns/{id}/approve` | `sale.refund` @outlet, bukan pembuat | `{refundReference?}` → `COMPLETED` + refund; idempotent |
| POST | `/api/returns/{id}/reject` | pembuat atau `sale.refund` | `{reason}` min 5 karakter → `REJECTED` (sisa jumlah kembali tersedia); idempotent |

Refund dialokasikan database ke pembayaran asli (`originalPaymentId`); mode `CASH` = semua tunai dari laci kasir
pemroses, mode `ORIGINAL` = bagian non-tunai dikembalikan ke metodenya (wajib `refundReference`), bagian tunai dari laci.
Error baru: `RETURN_NOT_FOUND`, `REFUND_NOT_ALLOWED`, `RETURN_QUANTITY_EXCEEDED`, `RETURN_EMPTY`, `RETURN_CLOSED`,
`RETURN_PENDING` (tutup kasir), `REFUND_APPROVAL_REQUIRED`, `REFUND_EXCEEDS_PAYMENT`.

### Sinkronisasi Openbravo (Phase 9)

| Method | Path | Izin | Catatan |
|---|---|---|---|
| GET | `/api/sync/status` | `sync.view` (org atau outlet) / `sync.manage` | `{mode: DISABLED\|SIMULATOR\|HTTP, enabled, workerEnabled, counts[{jobType,status,count}], lastMasterSyncs[], oldestPendingAt}` |
| GET | `/api/sync/errors` | `sync.view` | job FAILED / MANUAL_REVIEW / RETRYING / menunggu dokumen lain (maks. 200) |
| GET | `/api/sync/jobs?status=&jobType=` | `sync.view` | daftar job terbaru |
| GET | `/api/sync/jobs/{id}` | `sync.view` | job + riwayat percobaan (`logs`) |
| POST | `/api/sync/run` | `sync.manage` org | `{types?: [MASTER_PRODUCT\|MASTER_PRICE\|MASTER_STOCK\|MASTER_CUSTOMER]}` → minta sinkron master lalu proses antrean yang jatuh tempo; `{requested[], summary{processed, success, failed, deferred, busy}}`; `OPENBRAVO_UNAVAILABLE` bila integrasi DISABLED |
| POST | `/api/sync/{id}/retry` | `sync.manage` org | job FAILED / MANUAL_REVIEW → RETRYING (jatah percobaan baru); `SYNC_JOB_NOT_RETRYABLE` |
| GET | `/api/admin/openbravo-mappings` | `configuration.manage` atau `sync.view` (org) | semua entitas POS yang perlu dipetakan + ID Openbravo-nya |
| PUT | `/api/admin/openbravo-mappings` | `configuration.manage` org | `{entityType: ORGANIZATION\|OUTLET\|WAREHOUSE\|TERMINAL\|PAYMENT_METHOD\|TAX, posId, openbravoId}` |

Kontrak payload & respons Openbravo: [OPENBRAVO.md](OPENBRAVO.md). Error baru: `SYNC_JOB_NOT_RETRYABLE`, `MAPPING_INVALID`.

