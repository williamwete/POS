package com.pirantisolution.pos.attendance;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.attendance.AttendanceDtos.BreakStartRequest;
import com.pirantisolution.pos.attendance.AttendanceDtos.ClockInRequest;
import com.pirantisolution.pos.attendance.AttendanceDtos.ForceClockOutRequest;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import jakarta.validation.Valid;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class AttendanceController {

    private final AttendanceService service;
    private final IdempotencyService idempotency;

    public AttendanceController(AttendanceService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    /** Kehadiran yang sedang terbuka (null jika belum clock in). */
    @GetMapping("/api/attendance/current")
    public ResponseEntity<ApiResponse<AttendanceView>> current() {
        return Responses.ok(service.current().orElse(null));
    }

    @PostMapping("/api/attendance/clock-in")
    public ResponseEntity<?> clockIn(@Valid @RequestBody ClockInRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/attendance/clock-in", req,
                () -> Responses.created(service.clockIn(req.outletId()), "Clock in berhasil"));
    }

    @PostMapping("/api/attendance/break/start")
    public ResponseEntity<?> startBreak(@Valid @RequestBody(required = false) BreakStartRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        String reason = req == null ? null : req.reason();
        return idempotency.execute(key, "POST", "/api/attendance/break/start", reason == null ? Map.of() : Map.of("reason", reason),
                () -> Responses.ok(service.startBreak(reason), "Istirahat dimulai"));
    }

    @PostMapping("/api/attendance/break/end")
    public ResponseEntity<?> endBreak(
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/attendance/break/end", Map.of(),
                () -> Responses.ok(service.endBreak(), "Istirahat selesai"));
    }

    @PostMapping("/api/attendance/clock-out")
    public ResponseEntity<?> clockOut(
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/attendance/clock-out", Map.of(),
                () -> Responses.ok(service.clockOut(), "Clock out berhasil"));
    }

    @PostMapping("/api/attendance/{id}/force-clock-out")
    public ResponseEntity<?> forceClockOut(@PathVariable UUID id, @Valid @RequestBody ForceClockOutRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/attendance/" + id + "/force-clock-out", req,
                () -> Responses.ok(service.forceClockOut(id, req.reason()), "Kehadiran ditutup paksa"));
    }

    /** Riwayat kehadiran milik user yang login. */
    @GetMapping("/api/attendance/history")
    public ResponseEntity<ApiResponse<List<AttendanceView>>> history(
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return Responses.ok(service.myHistory(from, to));
    }

    /** Kehadiran satu outlet pada satu business date (attendance.view). */
    @GetMapping("/api/attendance")
    public ResponseEntity<ApiResponse<List<AttendanceView>>> outlet(
            @RequestParam UUID outletId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate businessDate,
            @RequestParam(required = false) String status) {
        return Responses.ok(service.outletAttendance(outletId, businessDate, status));
    }
}
