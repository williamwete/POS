# Operasi: backup per merchant, UU PDP, monitoring

## 1. Isolasi antar-tenant (dijaga otomatis)
`db/tests/test_20_tenant_guard.sql` gagal bila: ada tabel di schema `pos` tanpa RLS; ada tabel tanpa policy di luar daftar tertutup yang dikenal; role aplikasi dapat membaca tabel tertutup; atau pemilik sebuah merchant melihat baris ber-`organization_id` org lain di tabel mana pun. Tabel baru dengan kolom `organization_id` otomatis ikut diperiksa. Jalankan di CI pada setiap perubahan.

## 2. Backup & ekspor per merchant
Backup penuh database tetap lewat backup managed (Supabase PITR/daily). Untuk satu merchant:

    python3 -I db/ops/export_merchant.py "<conn-string owner db>" <KODE> <folder>

Menghasilkan CSV per tabel + `MANIFEST.csv` (jumlah baris). Tabel anak ditemukan lewat rantai foreign key; hash PIN dikosongkan. Dipakai untuk: (a) arsip sebelum penangguhan/penghapusan, (b) permintaan data subjek. Skrip hanya membaca; jalankan sebagai owner database, bukan `pos_api`.
Uji restore berkala: muat backup penuh ke database staging, jalankan `db/tests/run.sh`-style smoke test, catat hasilnya.

## 3. UU PDP (UU 27/2022) — daftar kerja
Bukan nasihat hukum; konfirmasikan dengan konsultan hukum.
- **Peran:** merchant = pengendali data; platform = prosesor data. Siapkan perjanjian pemrosesan data (DPA) dan syarat layanan untuk merchant.
- **Data pribadi yang disimpan:** karyawan (nama, email, foto absensi, PIN ter-hash), pelanggan (nama/kontak bila diisi), akun user, log audit, rekening bank merchant.
- **Hak subjek data:** akses/salinan → ekspor per merchant (di atas), disaring ke subjek; koreksi → lewat aplikasi; penghapusan → nonaktifkan user/pelanggan; data transaksi dipertahankan untuk kewajiban akuntansi/pajak (periode retensi ditetapkan merchant & hukum).
- **Retensi:** tetapkan kebijakan (mis. foto absensi 90 hari, log audit 1 tahun, transaksi sesuai ketentuan pajak) — belum ada penghapusan otomatis.
- **Keamanan:** RLS per org, secret hanya di env, foto/logo bukan URL publik. Enkripsi at-rest dan TLS dari penyedia hosting.
- **Insiden:** siapkan prosedur pemberitahuan kebocoran ke subjek data/otoritas (batas 3x24 jam menurut UU PDP).

## 4. Monitoring
- Probe: `/actuator/health/liveness` dan `/readiness` (tidak diteruskan nginx ke publik; hanya jaringan internal).
- Pantau dari luar: uptime check ke halaman login frontend dan `/api/health` via proxy bila disediakan.
- Log terstruktur ECS (profile `prod`); alarm pada lonjakan 5xx, `PLAN_LIMIT_EXCEEDED` massal, kegagalan login, dan antrean `sync_jobs` yang menumpuk/gagal.
- Keuangan: pantau pencairan berstatus REQUESTED > 2 hari dan saldo ledger negatif.
- Belum dibuat: endpoint metrik Prometheus (butuh auth scraper) dan dasbor alarm.

## 5. Hardening (Fase 12, bagian 1)
- **Header keamanan frontend** (`frontend/security-headers.inc`, di-include di setiap `location` nginx): CSP ketat (`script-src 'self'`, tanpa skrip inline; `connect-src` hanya same-origin dan `*.supabase.co`), `X-Frame-Options`/`frame-ancestors` DENY, `nosniff`, `Referrer-Policy`, `Permissions-Policy` (kamera hanya untuk situs sendiri). Sebelumnya header hanya terpasang di level server sehingga tidak ikut terkirim pada halaman SPA (`add_header` di dalam `location` menimpa warisan). Bila memakai domain kustom Supabase, tambahkan ke `connect-src`. HSTS dipasang di terminator TLS (load balancer/CDN), bukan di container ini.
- **Dependensi:** Dependabot mingguan (npm, Gradle) dan bulanan (GitHub Actions, Docker); CI menjalankan `npm audit --omit=dev --audit-level=high` dan gagal bila ada celah high/critical di dependensi produksi frontend.
- Sudah ada sebelumnya: rate limit API (`RateLimitFilter`), RLS dan penjaga isolasi tenant (tes 20), audit append-only, token JWT divalidasi issuer/audience/role.
- **Belum:** pemindaian dependensi backend di CI (Gradle), endpoint metrik, retensi otomatis foto absensi/log audit, uji restore terjadwal, pemindaian image container.
