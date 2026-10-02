package com.pirantisolution.pos.common.error;

import java.time.DateTimeException;
import java.time.ZoneId;
import java.util.Optional;

/** Helper validasi & optimistic locking yang dipakai lintas modul. */
public final class Guards {

    private Guards() {
    }

    /**
     * Hasil UPDATE ... WHERE version = :version RETURNING. Kosong berarti versi berbeda
     * (baris sudah diubah orang lain) karena keberadaan & izin sudah dicek sebelumnya.
     */
    public static <T> T requireUpdated(Optional<T> updated) {
        return updated.orElseThrow(() -> new ApiException(ErrorCode.CONCURRENT_MODIFICATION));
    }

    public static String validTimezoneOrNull(String tz) {
        if (tz == null || tz.isBlank()) {
            return null;
        }
        try {
            return ZoneId.of(tz).getId();
        } catch (DateTimeException e) {
            throw ApiException.validation("Timezone tidak dikenal: " + tz);
        }
    }

    public static String trimToNull(String value) {
        if (value == null) {
            return null;
        }
        String t = value.trim();
        return t.isEmpty() ? null : t;
    }
}
