# Milestone Phase 2 — Attendance

Tanggal: 2026-10-02 · Format §108.

## 1. What was implemented
- Clock in, istirahat (mulai/selesai), clock out untuk karyawan yang login (§11, §12).
- Layar kunci POS selama istirahat (§12).
- Force clock out oleh supervisor/manager dengan alasan wajib (§55).
- Riwayat kehadiran pribadi dan tampilan kehadiran outlet per business date.
- Audit `CLOCK_IN`, `BREAK_START`, `BREAK_END`, `CLOCK_OUT`, `FORCE_CLOCK_OUT` (§47).

## 2. Files created/changed
- `db/migration/V009__attendance.sql`, `db/tests/test_07_attendance.sql`
- `backend/.../attendance/*` (DTO, repository, service, controller), `ErrorCode`, `GlobalExceptionHandler`
- `backend/src/test/.../AttendanceIT.java`
- `frontend/src/stores/attendance.ts`, `frontend/src/modules/attendance/*`, router, layout, beranda
- `docs/API.md`, `docs/DATABASE.md`, `docs/ASSUMPTIONS.md` (B15–B17)

## 3. Database migrations
V009: `attendance`, `attendance_breaks`, trigger penjaga transisi, unique index satu kehadiran
terbuka per karyawan & satu istirahat terbuka per kehadiran, RLS.

## 4. API endpoints
Lihat [API.md](API.md) bagian attendance (8 endpoint).

## 5. Business rules
- Waktu clock in/out & istirahat **selalu dari server database**; nilai dari client diabaikan.
- Business date dihitung saat clock in (timezone outlet + cutoff) dan tidak berubah.
- Satu kehadiran terbuka per karyawan (aman terhadap request paralel).
- Transisi sah: WORKING ⇄ ON_BREAK, WORKING → COMPLETED, WORKING/ON_BREAK → FORCED_CLOSED.
  Kehadiran yang sudah ditutup tidak bisa dibuka atau diubah.
- Clock out ditolak selama istirahat berjalan; force clock out menutup istirahat otomatis.
- Istirahat bisa dimatikan per outlet (`break_enabled`).

## 6. Security rules
- Clock in hanya untuk diri sendiri dan di outlet tempat user punya `attendance.clock_in`.
- Kasir hanya melihat kehadirannya sendiri; `attendance.view` melihat kehadiran outlet.
- Force clock out butuh `attendance.force_clock_out` di outlet tersebut, tidak untuk diri sendiri.
- Tidak ada DELETE; semua aturan juga ditegakkan RLS + trigger, bukan hanya service.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL attendance (`test_07`) | 31 asersi (total SQL 167) |
| Backend `AttendanceIT` | 6 test: alur sehari penuh + audit, scope outlet, tanpa clock in, force clock out, kasir tidak melihat kehadiran outlet, clock in paralel |
| Frontend | 4 test durasi kerja (total 19) |

## 8. Known limitations
- Pemeriksaan cashier session saat clock out menyusul Phase 3 (B15).
- Belum ada koreksi jam kehadiran (B16).
- Layar kunci istirahat adalah UX; penolakan transaksi saat istirahat ditegakkan backend mulai Phase 4.

## 9. How to run
Sama seperti Phase 1 (`docker compose up --build`). Login sebagai `cashier.jkt@demo.local`,
pilih terminal, tekan **Clock in** di beranda. Supervisor: `supervisor.jkt@demo.local` → menu
**Kehadiran outlet**.

## 10. How to rollback
Aplikasi: deploy image sebelumnya. Database: V009 hanya menambah tabel baru; rollback pada
lingkungan tanpa data produksi = `DROP TABLE pos.attendance_breaks, pos.attendance;` lalu hapus
baris V009 di `flyway_schema_history`. Di production gunakan forward-fix.
