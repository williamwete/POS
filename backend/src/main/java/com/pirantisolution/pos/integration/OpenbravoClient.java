package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/**
 * Konektor ke Openbravo (§38). Implementasi berjalan di backend saja; kredensial tidak pernah ke frontend.
 * Semua data master dikembalikan dalam bentuk ternormalisasi (lihat docs/OPENBRAVO.md) sehingga upsert di
 * database tidak bergantung versi/format API Openbravo.
 */
public interface OpenbravoClient {

    enum MasterType { PRODUCT, PRICE, STOCK, CUSTOMER }

    /** Nama konektor untuk status/audit (DISABLED, SIMULATOR, HTTP). */
    String mode();

    /** false = antrean tetap terkumpul tetapi tidak dikirim. */
    boolean enabled();

    List<JsonNode> fetch(MasterType type);

    /** Kirim dokumen (SALE, RETURN, CASHUP). Harus idempotent di sisi Openbravo berdasarkan {@code externalId}. */
    DocumentRef post(String documentType, JsonNode payload);

    record DocumentRef(String documentId, String documentNo) {
    }

    /** Kegagalan Openbravo. {@code permanent} = tidak berguna di-retry (data ditolak), langsung manual review. */
    class OpenbravoException extends RuntimeException {

        private final boolean permanent;

        public OpenbravoException(String message, boolean permanent) {
            super(message);
            this.permanent = permanent;
        }

        public OpenbravoException(String message, boolean permanent, Throwable cause) {
            super(message, cause);
            this.permanent = permanent;
        }

        public boolean permanent() {
            return permanent;
        }
    }
}
