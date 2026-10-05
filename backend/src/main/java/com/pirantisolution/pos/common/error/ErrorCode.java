package com.pirantisolution.pos.common.error;

import org.springframework.http.HttpStatus;

/**
 * Kode error stabil yang dipakai frontend untuk menampilkan pesan human readable (§99).
 */
public enum ErrorCode {
    // umum
    VALIDATION_FAILED(HttpStatus.BAD_REQUEST, "Data yang dikirim tidak valid"),
    MALFORMED_REQUEST(HttpStatus.BAD_REQUEST, "Format request tidak valid"),
    NOT_FOUND(HttpStatus.NOT_FOUND, "Data tidak ditemukan"),
    CONCURRENT_MODIFICATION(HttpStatus.CONFLICT, "Data sudah diubah pengguna lain, muat ulang lalu coba lagi"),
    DUPLICATE_VALUE(HttpStatus.CONFLICT, "Data dengan nilai yang sama sudah ada"),
    RATE_LIMITED(HttpStatus.TOO_MANY_REQUESTS, "Terlalu banyak request, coba lagi sebentar"),
    INTERNAL_ERROR(HttpStatus.INTERNAL_SERVER_ERROR, "Terjadi kesalahan pada server"),

    // auth & otorisasi
    UNAUTHENTICATED(HttpStatus.UNAUTHORIZED, "Sesi login tidak valid atau sudah berakhir"),
    INVALID_CREDENTIALS(HttpStatus.UNAUTHORIZED, "Username atau password salah"),
    USER_NOT_PROVISIONED(HttpStatus.FORBIDDEN, "Akun belum terdaftar atau tidak aktif di POS"),
    USER_NOT_AUTHORIZED(HttpStatus.FORBIDDEN, "Anda tidak memiliki izin untuk aksi ini"),
    OUTLET_ACCESS_DENIED(HttpStatus.FORBIDDEN, "Anda tidak memiliki akses ke outlet ini"),
    ROLE_ASSIGNMENT_NOT_ALLOWED(HttpStatus.FORBIDDEN, "Anda tidak dapat memberi atau mencabut role ini"),
    SELF_MODIFICATION_NOT_ALLOWED(HttpStatus.FORBIDDEN, "Anda tidak dapat mengubah akses akun sendiri"),
    SYSTEM_ROLE_PROTECTED(HttpStatus.CONFLICT, "Role sistem tidak dapat diubah dengan cara ini"),

    // idempotency
    IDEMPOTENCY_KEY_INVALID(HttpStatus.BAD_REQUEST, "Idempotency-Key tidak valid"),
    IDEMPOTENCY_KEY_REUSED(HttpStatus.UNPROCESSABLE_ENTITY,
            "Idempotency-Key sudah dipakai untuk request yang berbeda"),
    DUPLICATE_TRANSACTION(HttpStatus.CONFLICT, "Transaksi duplikat terdeteksi"),

    // master data
    AUTH_USER_EXISTS(HttpStatus.CONFLICT, "Email sudah terdaftar di sistem login"),
    AUTH_PROVIDER_UNAVAILABLE(HttpStatus.SERVICE_UNAVAILABLE, "Layanan login sedang tidak tersedia"),
    EMPLOYEE_ALREADY_LINKED(HttpStatus.CONFLICT, "Karyawan sudah terhubung ke akun lain"),
    INVALID_DEVICE(HttpStatus.UNPROCESSABLE_ENTITY, "Device tidak valid untuk terminal ini"),
    SETTING_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Nilai konfigurasi tidak valid"),

    // attendance (Phase 2)
    EMPLOYEE_NOT_LINKED(HttpStatus.UNPROCESSABLE_ENTITY, "Akun Anda belum terhubung ke data karyawan"),
    EMPLOYEE_INACTIVE(HttpStatus.UNPROCESSABLE_ENTITY, "Data karyawan Anda tidak aktif"),
    ATTENDANCE_ALREADY_OPEN(HttpStatus.CONFLICT, "Anda sudah clock in dan belum clock out"),
    NO_ACTIVE_ATTENDANCE(HttpStatus.CONFLICT, "Anda belum clock in"),
    ALREADY_ON_BREAK(HttpStatus.CONFLICT, "Anda sedang istirahat"),
    NOT_ON_BREAK(HttpStatus.CONFLICT, "Anda tidak sedang istirahat"),
    BREAK_IN_PROGRESS(HttpStatus.CONFLICT, "Akhiri istirahat sebelum clock out"),
    BREAK_DISABLED(HttpStatus.UNPROCESSABLE_ENTITY, "Fitur istirahat tidak aktif di outlet ini"),
    ATTENDANCE_CLOSED(HttpStatus.CONFLICT, "Kehadiran ini sudah ditutup"),

    // cashier session (Phase 3)
    TERMINAL_ALREADY_OPEN(HttpStatus.CONFLICT, "Terminal sudah memiliki cashier session aktif"),
    CASHIER_SESSION_NOT_FOUND(HttpStatus.NOT_FOUND, "Cashier session tidak ditemukan"),
    CASHIER_SESSION_ALREADY_OPEN(HttpStatus.CONFLICT, "Anda masih memiliki cashier session aktif"),
    CASHIER_SESSION_OPEN(HttpStatus.CONFLICT, "Tutup kasir terlebih dahulu sebelum clock out"),
    CASHIER_SESSION_CLOSED(HttpStatus.CONFLICT, "Cashier session ini sudah ditutup"),
    CASHIER_SESSION_LOCKED(HttpStatus.CONFLICT, "Terminal sedang terkunci"),
    CASHIER_SESSION_NOT_LOCKED(HttpStatus.CONFLICT, "Terminal tidak sedang terkunci"),
    CASHIER_SESSION_HAS_ACTIVITY(HttpStatus.CONFLICT,
            "Session sudah memiliki aktivitas kas, tidak bisa dibatalkan (gunakan tutup kasir)"),
    ATTENDANCE_REQUIRED(HttpStatus.CONFLICT, "Clock in di outlet ini terlebih dahulu (dan selesaikan istirahat)"),
    TERMINAL_INACTIVE(HttpStatus.UNPROCESSABLE_ENTITY, "Terminal tidak aktif"),
    TERMINAL_MISMATCH(HttpStatus.CONFLICT, "Cashier session Anda terbuka di terminal lain"),
    REAUTH_REQUIRED(HttpStatus.FORBIDDEN, "Masukkan password Anda lagi untuk membuka kunci terminal"),
    DENOMINATION_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Denominasi uang tidak valid"),
    OPENING_CASH_MISMATCH(HttpStatus.CONFLICT, "Modal awal tidak cocok dengan hitungan kas"),

    // penjualan (Phase 4)
    CASHIER_SESSION_REQUIRED(HttpStatus.CONFLICT, "Buka kasir terlebih dahulu sebelum bertransaksi"),
    SALE_NOT_FOUND(HttpStatus.NOT_FOUND, "Transaksi tidak ditemukan"),
    SALE_NOT_EDITABLE(HttpStatus.CONFLICT, "Transaksi ini tidak bisa diubah lagi"),
    SALE_CLOSED(HttpStatus.CONFLICT, "Transaksi ini sudah dibatalkan"),
    SALE_EMPTY(HttpStatus.UNPROCESSABLE_ENTITY, "Keranjang masih kosong"),
    SALE_NOT_EMPTY(HttpStatus.CONFLICT, "Keranjang berisi barang; gunakan void dengan alasan"),
    PRODUCT_NOT_FOUND(HttpStatus.NOT_FOUND, "Produk tidak ditemukan"),
    PRODUCT_NOT_AVAILABLE(HttpStatus.UNPROCESSABLE_ENTITY, "Produk tidak dapat dijual"),
    PRICE_NOT_FOUND(HttpStatus.UNPROCESSABLE_ENTITY, "Harga produk belum tersedia di price list"),
    QUANTITY_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Jumlah tidak valid untuk produk ini"),
    APPROVAL_REQUIRED(HttpStatus.FORBIDDEN, "Tindakan ini memerlukan persetujuan supervisor"),
    APPROVER_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Email atau password approver salah"),
    APPROVER_NOT_AUTHORIZED(HttpStatus.FORBIDDEN, "Approver tidak berwenang menyetujui tindakan ini"),
    APPROVAL_EXPIRED(HttpStatus.CONFLICT, "Persetujuan sudah kedaluwarsa, minta persetujuan lagi"),
    DISCOUNT_LIMIT_EXCEEDED(HttpStatus.UNPROCESSABLE_ENTITY, "Diskon melebihi batas maksimum"),
    DISCOUNT_INVALID(HttpStatus.CONFLICT, "Diskon tidak sesuai dengan isi keranjang"),
    RECEIPT_NOT_AVAILABLE(HttpStatus.CONFLICT, "Struk belum tersedia; lakukan checkout terlebih dahulu"),

    // pembayaran (Phase 5)
    SALE_NOT_PAYABLE(HttpStatus.CONFLICT, "Lakukan checkout terlebih dahulu sebelum menerima pembayaran"),
    SALE_ALREADY_PAID(HttpStatus.CONFLICT, "Tagihan sudah terbayar penuh (atau tertutup pembayaran yang menunggu)"),
    SALE_NOT_FULLY_PAID(HttpStatus.CONFLICT, "Pembayaran belum mencukupi total transaksi"),
    SALE_HAS_PAYMENTS(HttpStatus.CONFLICT, "Batalkan pembayaran yang ada terlebih dahulu"),
    PAYMENT_NOT_FOUND(HttpStatus.NOT_FOUND, "Pembayaran tidak ditemukan"),
    PAYMENT_METHOD_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Metode pembayaran tidak tersedia"),
    PAYMENT_AMOUNT_INVALID(HttpStatus.UNPROCESSABLE_ENTITY, "Jumlah pembayaran tidak valid"),
    PAYMENT_EXCEEDS_REMAINING(HttpStatus.UNPROCESSABLE_ENTITY,
            "Pembayaran non-tunai tidak boleh melebihi sisa tagihan"),
    PAYMENT_REFERENCE_REQUIRED(HttpStatus.UNPROCESSABLE_ENTITY, "Nomor referensi pembayaran wajib diisi"),
    PAYMENT_CONFIRMATION_REQUIRED(HttpStatus.CONFLICT, "Menunggu konfirmasi dari penyedia pembayaran"),
    PAYMENT_NOT_REVERSIBLE(HttpStatus.CONFLICT, "Pembayaran ini tidak bisa dibatalkan; gunakan refund"),
    PAYMENT_CANCEL_REASON_REQUIRED(HttpStatus.UNPROCESSABLE_ENTITY, "Alasan pembatalan minimal 5 karakter"),
    PAYMENT_INVALID_TRANSITION(HttpStatus.CONFLICT, "Status pembayaran tidak bisa diubah dengan cara ini"),
    PAYMENT_GATEWAY_UNAVAILABLE(HttpStatus.SERVICE_UNAVAILABLE, "Penyedia pembayaran sedang tidak tersedia"),
    PAYMENT_CALLBACK_INVALID(HttpStatus.UNAUTHORIZED, "Callback pembayaran tidak valid"),

    // didefinisikan sekarang, dipakai phase berikutnya (§99)
    OPEN_ORDER_EXISTS(HttpStatus.CONFLICT, "Masih ada order yang belum selesai"),
    PAYMENT_PENDING(HttpStatus.CONFLICT, "Pembayaran masih pending"),
    PAYMENT_FAILED(HttpStatus.UNPROCESSABLE_ENTITY, "Pembayaran gagal"),
    INSUFFICIENT_PAYMENT(HttpStatus.UNPROCESSABLE_ENTITY, "Pembayaran kurang dari total"),
    STOCK_UNAVAILABLE(HttpStatus.UNPROCESSABLE_ENTITY, "Stok tidak mencukupi"),
    REFUND_NOT_ALLOWED(HttpStatus.UNPROCESSABLE_ENTITY, "Refund tidak diizinkan"),
    CASH_DIFFERENCE_REQUIRES_APPROVAL(HttpStatus.UNPROCESSABLE_ENTITY, "Selisih kas memerlukan approval"),
    OPENBRAVO_UNAVAILABLE(HttpStatus.SERVICE_UNAVAILABLE, "Openbravo sedang tidak tersedia"),
    SYNC_FAILED(HttpStatus.BAD_GATEWAY, "Sinkronisasi gagal");

    private final HttpStatus status;
    private final String defaultMessage;

    ErrorCode(HttpStatus status, String defaultMessage) {
        this.status = status;
        this.defaultMessage = defaultMessage;
    }

    public HttpStatus status() {
        return status;
    }

    public String defaultMessage() {
        return defaultMessage;
    }
}
