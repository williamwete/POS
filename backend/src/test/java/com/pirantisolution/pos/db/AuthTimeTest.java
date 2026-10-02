package com.pirantisolution.pos.db;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;

class AuthTimeTest {

    private static Jwt jwt(Object amr) {
        Jwt.Builder b = Jwt.withTokenValue("t").header("alg", "none").subject("s");
        if (amr != null) {
            b.claim("amr", amr);
        }
        return b.build();
    }

    @Test
    void takesLatestInteractiveAuthentication() {
        Jwt j = jwt(List.of(
                Map.of("method", "password", "timestamp", 1_700_000_000L),
                Map.of("method", "otp", "timestamp", 1_700_000_500L),
                Map.of("method", "token_refresh", "timestamp", 1_800_000_000L)));
        assertThat(RlsTransactionManager.authTime(j)).isEqualTo(1_700_000_500L);
    }

    @Test
    void missingOrMalformedAmrGivesNull() {
        assertThat(RlsTransactionManager.authTime(jwt(null))).isNull();
        assertThat(RlsTransactionManager.authTime(jwt("password"))).isNull();
        assertThat(RlsTransactionManager.authTime(jwt(List.of(Map.of("method", "password"))))).isNull();
    }
}
