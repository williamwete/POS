package com.pirantisolution.pos.attendance;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class AttendanceDtos {

    private AttendanceDtos() {
    }

    public record AttendanceView(
            UUID id,
            UUID employeeId,
            String employeeCode,
            String employeeName,
            UUID outletId,
            String outletCode,
            LocalDate businessDate,
            OffsetDateTime clockIn,
            OffsetDateTime clockOut,
            String status,
            String deviceId,
            String forcedReason,
            String clockOutByUsername,
            long breakSeconds,
            int version,
            List<BreakView> breaks) {

        AttendanceView withBreaks(List<BreakView> b) {
            long total = b.stream().mapToLong(x -> x.durationSeconds() == null ? 0 : x.durationSeconds()).sum();
            return new AttendanceView(id, employeeId, employeeCode, employeeName, outletId, outletCode, businessDate,
                    clockIn, clockOut, status, deviceId, forcedReason, clockOutByUsername, total, version, b);
        }
    }

    public record BreakView(UUID id, OffsetDateTime breakStart, OffsetDateTime breakEnd, Integer durationSeconds,
            String reason) {
    }

    public record ClockInRequest(@NotNull UUID outletId) {
    }

    public record BreakStartRequest(@Size(max = 200) String reason) {
    }

    public record ForceClockOutRequest(@NotBlank @Size(min = 5, max = 500) String reason) {
    }
}
