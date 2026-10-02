package com.pirantisolution.pos.auth;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Konteks login lengkap (§6): profil, employee, role, akses outlet, permission. */
public record MeResponse(
        UserInfo user,
        EmployeeInfo employee,
        OrganizationInfo organization,
        List<RoleAssignment> roles,
        List<String> organizationPermissions,
        List<OutletAccess> outlets) {

    public record UserInfo(UUID id, String username, String email, String displayName,
            OffsetDateTime lastLoginAt) {
    }

    public record EmployeeInfo(UUID id, String employeeCode, String fullName, String position,
            UUID homeOutletId) {
    }

    public record OrganizationInfo(UUID id, String code, String name, String timezone, String currency) {
    }

    public record RoleAssignment(UUID roleId, String roleCode, String roleName, UUID outletId, String outletCode) {
    }

    public record OutletAccess(UUID id, String code, String name, String timezone, boolean active,
            String businessDate, List<String> permissions) {
    }
}
