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
| GET | `/api/settings/effective?outletId=` | login / akses outlet | konfigurasi efektif §73 |
| GET | `/actuator/health/liveness`, `/readiness` | publik | probe |

Kode error: lihat `backend/.../common/error/ErrorCode.java`; pesan human readable di
`frontend/src/utils/errorMessages.ts`.
