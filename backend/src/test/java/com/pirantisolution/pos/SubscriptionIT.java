package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class SubscriptionIT extends IntegrationTestBase {

    @Test
    void merchantSeesOwnSubscription() throws Exception {
        var res = getAs("owner", "/api/subscription");
        assertThat(res.getResponse().getStatus()).isEqualTo(200);
        var data = body(res).get("data");
        assertThat(data.get("planCode").asText()).isEqualTo("ENTERPRISE");
        assertThat(data.get("expired").asBoolean()).isFalse();
    }
}
