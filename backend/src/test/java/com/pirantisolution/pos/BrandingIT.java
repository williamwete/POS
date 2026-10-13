package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Branding per merchant: semua boleh membaca, hanya pengelola struk yang boleh mengubah. */
class BrandingIT extends IntegrationTestBase {

    private static Map<String, Object> body(String name, String color, String logo) {
        Map<String, Object> m = new HashMap<>();
        m.put("displayName", name);
        m.put("primaryColor", color);
        m.put("logo", logo);
        return m;
    }

    @Test
    void ownerBrandsTheMerchantAndOthersOnlyRead() throws Exception {
        assertThat(getAs("supervisor.jkt", "/api/branding").getResponse().getStatus()).isEqualTo(200);
        assertThat(putAs("supervisor.jkt", "/api/branding", body("X", "#3F6A9E", null)).getResponse().getStatus()).isEqualTo(403);

        assertThat(putAs("owner", "/api/branding", body("Warung Maju", "nope", null)).getResponse().getStatus()).isEqualTo(400);
        assertThat(putAs("owner", "/api/branding", body("Warung Maju", "#FFFF99", null)).getResponse().getStatus()).isEqualTo(400);
        assertThat(putAs("owner", "/api/branding", body("Warung Maju", "#3F6A9E", "data:image/svg+xml;base64,PHN2Zz4="))
                .getResponse().getStatus()).isEqualTo(400);

        try {
            var saved = putAs("owner", "/api/branding", body("Warung Maju", "#0f7a6b", "data:image/png;base64,iVBORw0KGgo="));
            assertThat(saved.getResponse().getStatus()).as(saved.getResponse().getContentAsString()).isEqualTo(200);
            var seen = body(getAs("supervisor.jkt", "/api/branding")).at("/data");
            assertThat(seen.get("displayName").asText()).isEqualTo("Warung Maju");
            assertThat(seen.get("primaryColor").asText()).isEqualTo("#0F7A6B");
            assertThat(seen.get("organizationName").asText()).isNotBlank();
        } finally {
            putAs("owner", "/api/branding", body(null, null, null));
        }
    }
}
