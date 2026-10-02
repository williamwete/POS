package com.pirantisolution.pos.outlet;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class OutletDtos {

    private OutletDtos() {
    }

    public static final String CODE_REGEX = "^[A-Z0-9_-]{2,32}$";
    public static final String CODE_MESSAGE = "Kode 2-32 karakter: huruf besar, angka, - atau _";

    public record OutletView(
            UUID id,
            UUID organizationId,
            String code,
            String name,
            String address,
            String phone,
            String timezone,
            UUID defaultWarehouseId,
            boolean active,
            int version,
            OffsetDateTime createdAt,
            OffsetDateTime updatedAt) {
    }

    public record CreateOutletRequest(
            @NotBlank @Pattern(regexp = CODE_REGEX, message = CODE_MESSAGE) String code,
            @NotBlank @Size(max = 120) String name,
            @Size(max = 500) String address,
            @Size(max = 40) String phone,
            @Size(max = 64) String timezone) {
    }

    public record UpdateOutletRequest(
            @NotBlank @Size(max = 120) String name,
            @Size(max = 500) String address,
            @Size(max = 40) String phone,
            @Size(max = 64) String timezone,
            UUID defaultWarehouseId,
            @NotNull Boolean active,
            @NotNull Integer version) {
    }

    public record WarehouseView(
            UUID id,
            UUID organizationId,
            UUID outletId,
            String code,
            String name,
            boolean active,
            int version) {
    }

    public record CreateWarehouseRequest(
            UUID outletId,
            @NotBlank @Pattern(regexp = CODE_REGEX, message = CODE_MESSAGE) String code,
            @NotBlank @Size(max = 120) String name) {
    }
}
