package com.pirantisolution.pos.attendance;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.db.SystemTx;
import java.util.Base64;
import java.util.Optional;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

/**
 * Verifikasi bahwa yang clock in/out benar orangnya: PIN pribadi + foto (Figma "Clock in/Clock out").
 *
 * <p>Percobaan PIN dicatat lewat konteks sistem (transaksi terpisah) supaya hitungan salah tidak ikut
 * di-rollback ketika request ditolak. Hash PIN tidak pernah keluar dari database.
 */
@Component
public class PresenceVerifier {

    /** Foto yang sudah divalidasi, siap disimpan setelah attendance dibuat. */
    public record Photo(String contentType, byte[] image) {
    }

    static final int MAX_BYTES = 500_000;

    private final JdbcClient jdbc;
    private final SystemTx systemTx;
    private final boolean enforce;

    public PresenceVerifier(JdbcClient jdbc, SystemTx systemTx,
            @Value("${pos.attendance.enforce-verification:true}") boolean enforce) {
        this.jdbc = jdbc;
        this.systemTx = systemTx;
        this.enforce = enforce;
    }

    /** Wajib verifikasi? (setting outlet; dapat dimatikan total di profile tertentu.) */
    public boolean required(UUID outletId) {
        if (!enforce) {
            return false;
        }
        Boolean v = jdbc.sql("SELECT (pos.get_setting('attendance_verification_required', CAST(:o AS uuid)))::boolean")
                .param("o", outletId).query(Boolean.class).single();
        return !Boolean.FALSE.equals(v);
    }

    /** Melempar ApiException bila PIN/foto tidak memenuhi syarat; mengembalikan foto bila verifikasi aktif. */
    public Optional<Photo> verify(UUID employeeId, UUID outletId, String pin, String photo) {
        if (!required(outletId)) {
            return Optional.empty();
        }
        if (pin == null || pin.isBlank()) {
            throw new ApiException(ErrorCode.PIN_REQUIRED);
        }
        if (photo == null || photo.isBlank()) {
            throw new ApiException(ErrorCode.PHOTO_REQUIRED);
        }
        Photo decoded = decode(photo);   // foto dicek dulu agar PIN tidak terhitung salah karena foto rusak
        String result = systemTx.system(() -> jdbc.sql("SELECT pos.verify_employee_pin(:e, :p)")
                .param("e", employeeId).param("p", pin.trim()).query(String.class).single());
        switch (result) {
            case "OK" -> {
                return Optional.of(decoded);
            }
            case "NOT_SET" -> throw new ApiException(ErrorCode.PIN_NOT_SET);
            case "LOCKED" -> throw new ApiException(ErrorCode.PIN_LOCKED);
            default -> {
                String left = result.contains(":") ? result.substring(result.indexOf(':') + 1) : "?";
                throw new ApiException(ErrorCode.PIN_INVALID, "PIN salah. Sisa percobaan: " + left);
            }
        }
    }

    /** Terima base64 polos atau data URL (data:image/jpeg;base64,...). Hanya JPEG. */
    static Photo decode(String photo) {
        String b64 = photo.contains(",") ? photo.substring(photo.indexOf(',') + 1) : photo;
        byte[] bytes;
        try {
            bytes = Base64.getMimeDecoder().decode(b64.trim());
        } catch (IllegalArgumentException e) {
            throw new ApiException(ErrorCode.PHOTO_INVALID);
        }
        boolean jpeg = bytes.length > 4 && (bytes[0] & 0xFF) == 0xFF && (bytes[1] & 0xFF) == 0xD8 && (bytes[2] & 0xFF) == 0xFF;
        if (!jpeg || bytes.length > MAX_BYTES) {
            throw new ApiException(ErrorCode.PHOTO_INVALID);
        }
        return new Photo("image/jpeg", bytes);
    }
}
