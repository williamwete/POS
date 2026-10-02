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

    // didefinisikan sekarang, dipakai phase berikutnya (§99)
    TERMINAL_ALREADY_OPEN(HttpStatus.CONFLICT, "Terminal sudah memiliki cashier session aktif"),
    CASHIER_SESSION_NOT_FOUND(HttpStatus.NOT_FOUND, "Cashier session tidak ditemukan"),
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
