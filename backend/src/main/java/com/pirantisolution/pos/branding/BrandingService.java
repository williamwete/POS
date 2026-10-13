package com.pirantisolution.pos.branding;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.branding.BrandingDtos.BrandingView;
import com.pirantisolution.pos.branding.BrandingDtos.SaveBrandingRequest;
import com.pirantisolution.pos.security.AccessService;
import java.util.Map;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Branding per merchant. Izin (receipt.manage tingkat organisasi) dan validasi warna/logo ada di fungsi database. */
@Service
public class BrandingService {

    private final JdbcClient jdbc;
    private final AccessService access;
    private final AuditService audit;

    public BrandingService(JdbcClient jdbc, AccessService access, AuditService audit) {
        this.jdbc = jdbc;
        this.access = access;
        this.audit = audit;
    }

    @Transactional(readOnly = true)
    public BrandingView get() {
        access.currentUser();
        return jdbc.sql("""
                SELECT o.name AS organization_name, b.display_name, b.primary_color, b.logo
                FROM pos.organizations o
                LEFT JOIN pos.organization_branding b ON b.organization_id = o.id
                WHERE o.id = pos.current_org_id()
                """).query(BrandingView.class).single();
    }

    @Transactional
    public BrandingView save(SaveBrandingRequest req) {
        access.currentUser();
        jdbc.sql("SELECT pos.save_branding(:name, :color, :logo)")
                .param("name", req.displayName()).param("color", req.primaryColor()).param("logo", req.logo())
                .query().singleRow();
        // logo tidak ikut ke audit (besar); cukup menandai ada/tidak
        audit.record(AuditEvent.of("BRANDING_UPDATED", "ORGANIZATION", access.currentUser().organizationId())
                .change(null, Map.of("displayName", String.valueOf(req.displayName()),
                        "primaryColor", String.valueOf(req.primaryColor()), "hasLogo", req.logo() != null && !req.logo().isBlank())));
        return get();
    }
}
