package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/** Integrasi belum dikonfigurasi: dokumen tetap mengantre (PENDING) sampai konektor diaktifkan. */
public class DisabledOpenbravoClient implements OpenbravoClient {

    @Override
    public String mode() {
        return "DISABLED";
    }

    @Override
    public boolean enabled() {
        return false;
    }

    @Override
    public List<JsonNode> fetch(MasterType type) {
        throw new OpenbravoException("Integrasi Openbravo belum dikonfigurasi", false);
    }

    @Override
    public DocumentRef post(String documentType, JsonNode payload) {
        throw new OpenbravoException("Integrasi Openbravo belum dikonfigurasi", false);
    }
}
