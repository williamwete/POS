package com.pirantisolution.pos.auth.provider;

import java.util.UUID;

/**
 * Operasi admin terhadap penyedia login (Supabase Auth). Credential penyedia hanya ada
 * di server. Password tidak pernah disimpan atau di-log oleh aplikasi POS.
 */
public interface AuthProviderAdmin {

    /** Membuat akun login; mengembalikan id auth user. */
    UUID createUser(String email, String password);

    /** Kompensasi jika langkah berikutnya gagal. */
    void deleteUser(UUID authUserId);

    void setPassword(UUID authUserId, String password);

    /** Memblokir/membuka login di sisi penyedia (dipakai saat user dinonaktifkan). */
    void setBanned(UUID authUserId, boolean banned);

    /**
     * Verifikasi email + password tanpa membuat sesi bagi pemanggil (dipakai approval supervisor
     * di terminal kasir). Mengembalikan id auth user, atau {@code null} bila salah.
     */
    UUID verifyPassword(String email, String password);
}
