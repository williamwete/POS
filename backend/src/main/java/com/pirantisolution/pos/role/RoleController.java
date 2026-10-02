package com.pirantisolution.pos.role;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.role.RoleService.PermissionView;
import com.pirantisolution.pos.role.RoleService.RoleView;
import com.pirantisolution.pos.role.RoleService.SetPermissionsRequest;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class RoleController {

    private final RoleService service;

    public RoleController(RoleService service) {
        this.service = service;
    }

    @GetMapping("/api/roles")
    public ResponseEntity<ApiResponse<List<RoleView>>> roles() {
        return Responses.ok(service.roles());
    }

    @GetMapping("/api/permissions")
    public ResponseEntity<ApiResponse<List<PermissionView>>> permissions() {
        return Responses.ok(service.permissions());
    }

    @PutMapping("/api/roles/{id}/permissions")
    public ResponseEntity<ApiResponse<RoleView>> setPermissions(@PathVariable UUID id,
            @Valid @RequestBody SetPermissionsRequest req) {
        return Responses.ok(service.setPermissions(id, req.permissionCodes()), "Permission role diperbarui");
    }
}
