package com.pirantisolution.pos.platform;

import com.pirantisolution.pos.platform.PlatformDtos.MerchantRow;
import com.pirantisolution.pos.platform.PlatformDtos.MerchantUserRow;
import com.pirantisolution.pos.platform.PlatformDtos.PlanRow;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** Semua akses lewat fungsi pos.platform_* yang memeriksa permission platform.manage. */
@Repository
public class PlatformRepository {

    private final JdbcClient jdbc;

    public PlatformRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    List<PlanRow> plans() {
        return jdbc.sql("SELECT * FROM pos.platform_plans()").query(PlanRow.class).list();
    }

    List<MerchantRow> merchants() {
        return jdbc.sql("SELECT * FROM pos.platform_list_merchants()").query(MerchantRow.class).list();
    }

    Optional<MerchantRow> merchant(UUID id) {
        return merchants().stream().filter(m -> m.id().equals(id)).findFirst();
    }

    List<MerchantUserRow> users(UUID org) {
        return jdbc.sql("SELECT * FROM pos.platform_merchant_users(:org)").param("org", org)
                .query(MerchantUserRow.class).list();
    }

    UUID provision(PlatformDtos.CreateMerchantRequest r, String code, String outletCode, String email, UUID authUserId) {
        return jdbc.sql("""
                SELECT pos.platform_provision_merchant(:code, :name, :type, :plan, :oc, :on, :owner, :email, :auth, 'Asia/Jakarta')
                """)
                .param("code", code).param("name", r.name().trim()).param("type", r.businessType())
                .param("plan", r.plan()).param("oc", outletCode).param("on", r.outletName().trim())
                .param("owner", r.ownerName().trim()).param("email", email).param("auth", authUserId)
                .query(UUID.class).single();
    }

    void applyPreset(UUID org) {
        jdbc.sql("SELECT pos.platform_apply_preset(:org)").param("org", org).query().singleRow();
    }

    void setPlan(UUID org, String plan) {
        jdbc.sql("SELECT pos.platform_set_plan(:org, :plan)").param("org", org).param("plan", plan)
                .query().singleRow();
    }

    void setActive(UUID org, boolean active, String reason) {
        jdbc.sql("SELECT pos.platform_set_active(:org, :active, :reason)").param("org", org)
                .param("active", active).param("reason", reason).query().singleRow();
    }
}
