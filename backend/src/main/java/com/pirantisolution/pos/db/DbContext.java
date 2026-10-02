package com.pirantisolution.pos.db;

import java.util.function.Supplier;

/**
 * Menentukan role database untuk transaksi yang DIMULAI pada thread ini.
 *
 * <ul>
 *   <li>{@link Mode#USER} (default): {@code SET LOCAL ROLE pos_app_user} + klaim JWT request.
 *       Tanpa JWT, tidak ada role yang di-set sehingga pos_api tidak punya privilege (fail-closed).</li>
 *   <li>{@link Mode#SYSTEM}: {@code SET LOCAL ROLE pos_system} untuk job sistem / bootstrap.</li>
 *   <li>{@link Mode#LOCAL_AUTH}: khusus profile local untuk verifikasi password shim auth.</li>
 * </ul>
 *
 * Mode hanya berlaku untuk transaksi baru (gunakan {@link SystemTx}).
 */
public final class DbContext {

    public enum Mode { USER, SYSTEM, LOCAL_AUTH }

    private static final ThreadLocal<Mode> OVERRIDE = new ThreadLocal<>();

    private DbContext() {
    }

    public static Mode currentMode() {
        Mode m = OVERRIDE.get();
        return m != null ? m : Mode.USER;
    }

    static <T> T callAs(Mode mode, Supplier<T> action) {
        Mode previous = OVERRIDE.get();
        OVERRIDE.set(mode);
        try {
            return action.get();
        } finally {
            if (previous == null) {
                OVERRIDE.remove();
            } else {
                OVERRIDE.set(previous);
            }
        }
    }
}
