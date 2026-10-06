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

