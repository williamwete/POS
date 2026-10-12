package com.pirantisolution.pos.menu;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Menu per role (Figma side menu). Menu hanyalah lapisan tampilan: izin API tetap dari permission + RLS.
 * Owner/Admin (permission menu.configure) mengaktifkan/menonaktifkan menu per peran; tanpa pengaturan,
 * berlaku default di tabel menu_defaults.
 */
@RestController
public class MenuController {

    public record MenuItem(String code, String label, String routeName, int sortOrder) {
    }

    public record MatrixCell(String menuCode, String label, String roleCode, boolean enabled, boolean defaultEnabled,
            int sortOrder) {
    }

    /** enabled = null mengembalikan ke default. */
    public record SetMenuRequest(@NotBlank String menuCode, @NotBlank String roleCode, Boolean enabled) {
    }

    private final JdbcClient jdbc;
    private final AuditService audit;

    public MenuController(JdbcClient jdbc, AuditService audit) {
        this.jdbc = jdbc;
        this.audit = audit;
    }

    /** Menu yang boleh dilihat user saat ini pada outlet terpilih. */
    @GetMapping("/api/menus/me")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<List<MenuItem>>> mine(@RequestParam(required = false) UUID outletId) {
        return Responses.ok(jdbc.sql("SELECT code, label, route_name, sort_order FROM pos.my_menus(CAST(:o AS uuid))")
                .param("o", outletId)
                .query((rs, n) -> new MenuItem(rs.getString("code"), rs.getString("label"), rs.getString("route_name"),
                        rs.getInt("sort_order")))
                .list());
    }

    @GetMapping("/api/admin/menus")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<List<MatrixCell>>> matrix() {
        return Responses.ok(jdbc.sql("SELECT menu_code, label, role_code, enabled, default_enabled, sort_order FROM pos.menu_matrix()")
                .query((rs, n) -> new MatrixCell(rs.getString("menu_code"), rs.getString("label"), rs.getString("role_code"),
                        rs.getBoolean("enabled"), rs.getBoolean("default_enabled"), rs.getInt("sort_order")))
                .list());
    }

    @PutMapping("/api/admin/menus")
    @Transactional
    public ResponseEntity<ApiResponse<List<MatrixCell>>> set(@Valid @RequestBody SetMenuRequest req) {
        jdbc.sql("SELECT pos.set_menu_enabled(:m, :r, CAST(:e AS boolean))")
                .param("m", req.menuCode()).param("r", req.roleCode()).param("e", req.enabled())
                .query().singleRow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("menu", req.menuCode());
        v.put("role", req.roleCode());
        v.put("enabled", req.enabled() == null ? "DEFAULT" : req.enabled());
        audit.record(AuditEvent.of("MENU_SETTING_CHANGED", "MENU", null).change(null, v));
        return matrix();
    }
}
