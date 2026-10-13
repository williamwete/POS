package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class SubscriptionIT extends IntegrationTestBase {

    @Test
    void merchantSeesOwnSubscription() throws Exception {
        var res = getAs("owner", "/api/subscription");
        assertThat(res.getResponse().getStatus()).isEqualTo(200);
        // Organisasi tanpa baris langganan (data uji) = tanpa batas, jadi datanya kosong.
        var data = body(res).get("data");
        if (data != null && !data.isNull()) {
            assertThat(data.get("expired").asBoolean()).isFalse();
        }
    }
}
