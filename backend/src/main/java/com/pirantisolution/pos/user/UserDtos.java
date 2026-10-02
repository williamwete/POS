package com.pirantisolution.pos.user;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class UserDtos {

    private UserDtos() {
    }

    public record UserView(
            UUID id,
            String username,
            String email,
            String displayName,
            UUID employeeId,
            String employeeCode,
            String employeeName,
            boolean active,
            OffsetDateTime lastLoginAt,
            int version,
            List<RoleGrant> roles,
            List<OutletRef> outlets) {

        UserView withAccess(List<RoleGrant> r, List<OutletRef> o) {
            return new UserView(id, username, email, displayName, employeeId, employeeCode, employeeName,
                    active, lastLoginAt, version, r, o);
        }
    }

    public record RoleGrant(UUID roleId, String roleCode, String roleName, int rank, UUID outletId, String outletCode) {
    }

    public record OutletRef(UUID outletId, String outletCode, String outletName) {
    }

    /** outletId NULL = role berlaku org-wide. */
    public record RoleGrantRequest(@NotNull UUID roleId, UUID outletId) {
    }

    public record CreateUserRequest(
            @NotBlank @Pattern(regexp = "^[a-z0-9._-]{3,64}$",
                    message = "Username 3-64 karakter: huruf kecil, angka, titik, - atau _") String username,
            @NotBlank @Email @Size(max = 254) String email,
            @NotBlank @Size(max = 120) String displayName,
            UUID employeeId,
            @NotBlank @Size(min = 10, max = 72) String password,
            @NotNull @Size(max = 20) List<@Valid RoleGrantRequest> roles,
            @NotNull @Size(max = 200) List<@NotNull UUID> outletIds) {

        /** Password tidak pernah ikut tercetak di log / audit. */
        @Override
        public String toString() {
            return "CreateUserRequest[username=" + username + ", email=" + email + "]";
        }
    }

    public record UpdateUserRequest(
            @NotBlank @Size(max = 120) String displayName,
            UUID employeeId,
            @NotNull Boolean active,
            @NotNull Integer version) {
    }

    public record SetRolesRequest(@NotNull @Size(max = 20) List<@Valid RoleGrantRequest> roles) {
    }

    public record SetOutletsRequest(@NotNull @Size(max = 200) List<@NotNull UUID> outletIds) {
    }

    public record ResetPasswordRequest(@NotBlank @Size(min = 10, max = 72) String password) {
        @Override
        public String toString() {
            return "ResetPasswordRequest[***]";
        }
    }
}
