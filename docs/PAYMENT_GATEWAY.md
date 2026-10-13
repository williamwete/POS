# Checklist menyambungkan payment gateway

1. Daftar ke gateway (QRIS dinamis, callback/webhook). Tanyakan dukungan sub-merchant / split settlement dan API disbursement.
2. Buat kelas baru yang mengimplementasi `PaymentGateway` (create, status, cancel, verifyCallback) sesuai API gateway.
3. Set env: `POS_PAYMENT_GATEWAY=<nama>`, `POS_PAYMENT_CALLBACK_SECRET`, kredensial gateway.
4. Pastikan pembayaran tersimpan dengan provider + external_transaction_id + konfirmasi GATEWAY, supaya masuk ledger.
5. Sesuaikan biaya di `platform_set_terms` agar sama dengan tarif gateway + margin.
6. Uji di sandbox: bayar, callback, refund, ajukan dan proses pencairan.
7. Opsional: otomatisasi pencairan lewat API disbursement (saat ini manual oleh operator).
