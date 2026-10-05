package com.pirantisolution.pos.payment.gateway;

import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Tanda tangan callback pembayaran: hex(HMAC-SHA256(secret, timestamp + "." + body)).
 * Timestamp (epoch detik) wajib berada dalam jendela 5 menit agar callback lama tidak bisa diputar ulang.
 */
public final class CallbackSigner {

    public static final String SIGNATURE_HEADER = "X-POS-Signature";
    public static final String TIMESTAMP_HEADER = "X-POS-Timestamp";
    private static final Duration WINDOW = Duration.ofMinutes(5);

    private final byte[] secret;
    private final Clock clock;

    public CallbackSigner(String secret, Clock clock) {
        if (secret == null || secret.length() < 32) {
            throw new IllegalStateException("pos.payment.callback-secret wajib diisi (minimal 32 karakter)");
        }
        this.secret = secret.getBytes(StandardCharsets.UTF_8);
        this.clock = clock;
    }

    public String sign(String timestamp, String body) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret, "HmacSHA256"));
            byte[] digest = mac.doFinal((timestamp + "." + body).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException | InvalidKeyException e) {
            throw new IllegalStateException("HMAC tidak tersedia", e);
        }
    }

    /** Waktu sekarang dalam format header timestamp. */
    public String now() {
        return Long.toString(clock.instant().getEpochSecond());
    }

    public void verify(String body, String signature, String timestamp) {
        if (body == null || signature == null || timestamp == null) {
            throw new PaymentGateway.CallbackRejectedException("signature or timestamp missing");
        }
        long ts;
        try {
            ts = Long.parseLong(timestamp.trim());
        } catch (NumberFormatException e) {
            throw new PaymentGateway.CallbackRejectedException("invalid timestamp");
        }
        Instant sent = Instant.ofEpochSecond(ts);
        if (Duration.between(sent, clock.instant()).abs().compareTo(WINDOW) > 0) {
            throw new PaymentGateway.CallbackRejectedException("timestamp outside window");
        }
        byte[] expected = sign(timestamp.trim(), body).getBytes(StandardCharsets.US_ASCII);
        byte[] given = signature.trim().toLowerCase().getBytes(StandardCharsets.US_ASCII);
        if (!MessageDigest.isEqual(expected, given)) {
            throw new PaymentGateway.CallbackRejectedException("signature mismatch");
        }
    }
}
