# Milestone Phase 8 — Retur & refund

Tanggal: 2026-10-06 · Format §108.

## 1. What was implemented
- **Retur** (§28) merujuk struk asli: penuh, sebagian, per item, per jumlah; nomor `RET-<terminal>-<tanggal>-<urut>`.
  Transaksi asli tidak berubah (§86).
- Pencarian struk (ketik/scan) menampilkan jumlah terjual, sudah diretur, dan **sisa yang bisa diretur** per barang.
- **Refund** (§29) dengan `refund_id`, `return_id`, `original_payment_id`, jumlah, metode, status, approver, waktu:
  tunai dari laci kasir, atau ke metode bayar asal (debit/kredit/QRIS dengan nomor referensi) + sisanya tunai.
- **Persetujuan supervisor** wajib: di terminal kasir (email + password) atau dari akun supervisor (daftar
  "Menunggu persetujuan"); retur bisa ditolak/dibatalkan dengan alasan.
- Bukti retur 80 mm; refund masuk **Z report** (refund, penjualan bersih, refund tunai).
- Tutup kasir ditolak selama ada retur yang menunggu persetujuan.

## 2. Files created/changed
- `db/migration/V017__returns_refunds.sql`, `db/tests/test_13_returns.sql`, `db/tests/_helpers.sql`
- `backend/.../returns/*` (service, repository, controller, DTO, approval terminal), `ErrorCode`,
  `GlobalExceptionHandler`, `RateLimitFilter`
- `backend/src/test/.../ReturnsIT.java`
- `frontend/src/modules/returns/ReturnsPage.vue`, `ReturnPaper.vue`, `stores/returns.ts` (+ spec), `types/api.ts`,
  `router/index.ts`, `layouts/AppLayout.vue` (menu Retur), `utils/errorMessages.ts`
- Docs: API, DATABASE, ASSUMPTIONS (B51–B56), TESTING, README

## 3. Database migrations
V017: tabel `returns`, `return_items`, `refunds`, `terminal_return_sequences`; approval `REFUND`; trigger penjaga retur,
baris retur (sisa jumlah, nilai), refund otomatis + `CASH_REFUND`; blokir tutup kasir; fungsi `return_lookup`;
`compute_shift_report` menghitung refund; RLS.

## 4. API endpoints
7 endpoint — lihat [API.md](API.md) bagian "Retur & refund" (sesuai §72: `POST /api/returns`, `GET /api/returns/{id}`,
`POST /api/returns/{id}/approve`, plus lookup, daftar, approval di terminal, tolak).

## 5. Business rules
- Jumlah retur ≤ sisa (jumlah terjual − retur selesai/menunggu); diserialkan per transaksi asal (row lock).
- Nilai refund dihitung database dari nilai bersih baris; total refund tidak pernah melebihi yang dibayar.
- Refund dialokasikan ke pembayaran asli; bagian tunai keluar dari laci kasir pemroses (tidak boleh melebihi isi laci).
- Retur, baris, refund append-only; transaksi, baris, dan pembayaran asli tidak diubah.
- Z report: refund dan jumlah retur dari laci tsb; penjualan bersih = total transaksi − refund.

## 6. Security rules
- Refund restricted: approver dengan `sale.refund` dan rank ≥ SUPERVISOR, bukan pembuat; approval terminal sekali
  pakai, terikat transaksi & nominal; password tidak disimpan/di-log, endpoint dibatasi rate limit seperti login.
- Pencarian struk hanya di outlet tempat pemanggil bertransaksi/berwenang; struk outlet lain tidak terlihat.
- Semua aturan ditegakkan trigger + RLS; audit `RETURN_CREATED`, `APPROVAL`, `RETURN_COMPLETED`/`RETURN_APPROVED`,
  `RETURN_REJECTED`.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL retur (`test_13`) | 32 asersi (total SQL 408) |
| Backend `ReturnsIT` | 2 test: §86 retur 2 dari 10 (struk utuh, refund, duplikat ID, sisa jumlah, kasir tidak bisa menyetujui, approval terminal & akun supervisor, blokir tutup kasir, daftar, Z report, audit); tolak retur & struk outlet lain |
| Frontend | 1 test baru (baris retur); total 28 |

## 8. Known limitations
- Refund kartu/QRIS tidak terintegrasi otomatis — dicatat dengan nomor referensi dari EDC/penyedia (B54).
- Retur lintas outlet dan batas waktu retur belum ada (B51).
- Stok & dokumen retur ke Openbravo: Phase 9 (B56).

## 9. How to run
`docker compose up --build`. Kasir (kasir buka): menu **Retur** → scan/ketik nomor struk → isi jumlah retur & alasan →
**Buat retur** → **Setujui di terminal** (`supervisor.jkt@demo.local`) → serahkan uang → **Cetak bukti retur**.
Supervisor: menu **Retur** → **Menunggu persetujuan** → Setujui / Tolak.

## 10. How to rollback
Aplikasi: deploy image sebelumnya (menu Retur hilang). Database (tanpa data produksi): drop trigger & fungsi V017,
tabel `refunds`, `return_items`, `returns`, `terminal_return_sequences`; kembalikan `compute_shift_report` (rename
`compute_shift_report_base`), `tg_approval_guard` & policy `approvals_insert` dari V015, constraint `approvals_action_ck`;
hapus baris V017 di `flyway_schema_history`. Di production gunakan forward-fix (retur/refund adalah catatan keuangan).
