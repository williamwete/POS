package com.pirantisolution.pos.employee;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class EmployeeDtos {

    private EmployeeDtos() {
    }

    public record EmployeeView(
            UUID id,
            UUID organizationId,
            String employeeCode,
            String fullName,
            String phone,
            String email,
            String position,
            UUID homeOutletId,
            String homeOutletCode,
            LocalDate hireDate,
            boolean active,
            UUID linkedUserId,
            String linkedUsername,
            int version,
            OffsetDateTime updatedAt) {
    }

    public record CreateEmployeeRequest(
            @NotBlank @Pattern(regexp = "^[A-Z0-9_-]{2,32}$",
                    message = "Kode 2-32 karakter: huruf besar, angka, - atau _") String employeeCode,
            @NotBlank @Size(max = 120) String fullName,
            @Size(max = 40) String phone,
            @Email @Size(max = 254) String email,
            @Size(max = 80) String position,
            UUID homeOutletId,
            LocalDate hireDate) {
    }

    public record UpdateEmployeeRequest(
            @NotBlank @Size(max = 120) String fullName,
            @Size(max = 40) String phone,
            @Email @Size(max = 254) String email,
            @Size(max = 80) String position,
            UUID homeOutletId,
            LocalDate hireDate,
            @NotNull Boolean active,
            @NotNull Integer version) {
    }
}
