package com.pirantisolution.pos.terminal;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class TerminalDtos {

    private TerminalDtos() {
    }

    static final String CODE_REGEX = "^[A-Z0-9_-]{2,32}$";
    static final String CODE_MESSAGE = "Kode 2-32 karakter: huruf besar, angka, - atau _";
    static final String DEVICE_TYPE_REGEX = "^(BROWSER|PRINTER|CASH_DRAWER|SCANNER|CUSTOMER_DISPLAY)$";

    public record TerminalView(
            UUID id,
            UUID outletId,
            String outletCode,
            String code,
            String name,
            UUID deviceId,
            UUID printerId,
            String printerName,
            UUID cashDrawerId,
            String cashDrawerName,
            boolean active,
            int version,
            OffsetDateTime updatedAt) {
    }

    public record CreateTerminalRequest(
            @NotNull UUID outletId,
            @NotBlank @Pattern(regexp = CODE_REGEX, message = CODE_MESSAGE) String code,
            @NotBlank @Size(max = 80) String name,
            UUID deviceId,
            UUID printerId,
            UUID cashDrawerId) {
    }

    public record UpdateTerminalRequest(
            @NotBlank @Size(max = 80) String name,
            UUID deviceId,
            UUID printerId,
            UUID cashDrawerId,
            @NotNull Boolean active,
            @NotNull Integer version) {
    }

    public record DeviceView(
            UUID id,
            UUID outletId,
            String deviceType,
            String code,
            String name,
            String identifier,
            boolean active,
            OffsetDateTime lastSeenAt,
            int version) {
    }

    public record CreateDeviceRequest(
            @NotNull UUID outletId,
            @NotBlank @Pattern(regexp = DEVICE_TYPE_REGEX, message = "Tipe device tidak dikenal") String deviceType,
            @NotBlank @Pattern(regexp = CODE_REGEX, message = CODE_MESSAGE) String code,
            @NotBlank @Size(max = 80) String name,
            @Size(max = 200) String identifier) {
    }

    public record UpdateDeviceRequest(
            @NotBlank @Size(max = 80) String name,
            @Size(max = 200) String identifier,
            @NotNull Boolean active,
            @NotNull Integer version) {
    }
}
