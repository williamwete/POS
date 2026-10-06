package com.pirantisolution.pos.common.web;

import static org.assertj.core.api.Assertions.assertThat;

import com.pirantisolution.pos.config.PosProperties;
import org.junit.jupiter.api.Test;

/** Unit test tanpa database. */
class RateLimitFilterTest {

    @Test
    void blocksAfterLimitWithinWindow() {
        PosProperties props = new PosProperties(null, null, new PosProperties.Cors(java.util.List.of()),
                new PosProperties.RateLimit(true, 3, 1), null, null);
        RateLimitFilter filter = new RateLimitFilter(props, new com.fasterxml.jackson.databind.ObjectMapper());
        assertThat(filter.tryAcquire("k", 3)).isTrue();
        assertThat(filter.tryAcquire("k", 3)).isTrue();
        assertThat(filter.tryAcquire("k", 3)).isTrue();
        assertThat(filter.tryAcquire("k", 3)).isFalse();
        assertThat(filter.tryAcquire("other", 3)).isTrue();
    }
}
