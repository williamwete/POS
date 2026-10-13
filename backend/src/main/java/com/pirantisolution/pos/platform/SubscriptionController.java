package com.pirantisolution.pos.platform;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.security.AccessService;
import java.time.OffsetDateTime;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Status langganan merchant yang sedang login (untuk banner masa percobaan). */
@RestController
public class SubscriptionController {

    public record SubscriptionView(String planCode, String planName, String status, OffsetDateTime trialEndsAt, boolean expired) {
    }

    private final JdbcClient jdbc;
    private final AccessService access;

    public SubscriptionController(JdbcClient jdbc, AccessService access) {
        this.jdbc = jdbc;
        this.access = access;
    }

    @GetMapping("/api/subscription")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<SubscriptionView>> subscription() {
        access.currentUser();
        SubscriptionView v = jdbc.sql("SELECT plan_code, plan_name, status, trial_ends_at, expired FROM pos.my_subscription()")
                .query(SubscriptionView.class).optional().orElse(null);
        return Responses.ok(v);
    }
}
