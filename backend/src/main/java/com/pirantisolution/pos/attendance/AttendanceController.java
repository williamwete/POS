package com.pirantisolution.pos.attendance;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.attendance.AttendanceDtos.BreakStartRequest;
import com.pirantisolution.pos.attendance.AttendanceDtos.ClockInRequest;
import com.pirantisolution.pos.attendance.AttendanceDtos.ClockOutRequest;
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
    private final PresenceVerifier presence;

    public AttendanceController(AttendanceService service, IdempotencyService idempotency, PresenceVerifier presence) {
        this.presence = presence;
        this.service = service;
        this.idempotency = idempotency;
    }

    /** Kehadiran yang sedang terbuka (null jika belum clock in). */
    @GetMapping("/api/attendance/current")
    public ResponseEntity<ApiResponse<AttendanceView>> current() {
        return Responses.ok(service.current().orElse(null));
    }

    /** Apakah outlet mewajibkan PIN + foto saat clock in/out (agar UI menampilkan kamera). */
    @GetMapping("/api/attendance/verification")
    @org.springframework.transaction.annotation.Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<Map<String, Boolean>>> verification(@RequestParam UUID outletId) {
        return Responses.ok(Map.of("required", presence.required(outletId)));
    }

    @PostMapping("/api/attendance/clock-in")
    public ResponseEntity<?> clockIn(@Valid @RequestBody ClockInRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/attendance/clock-in", req,
                () -> Responses.created(service.clockIn(req.outletId(), req.pin(), req.photo()), "Clock in berhasil"));
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
    public ResponseEntity<?> clockOut(@Valid @RequestBody(required = false) ClockOutRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        String pin = req == null ? null : req.pin();
        String photo = req == null ? null : req.photo();
        return idempotency.execute(key, "POST", "/api/attendance/clock-out", req == null ? Map.of() : req,
                () -> Responses.ok(service.clockOut(pin, photo), "Clock out berhasil"));
    }

    /** Foto verifikasi (kind = CLOCK_IN | CLOCK_OUT): pemilik, atau role dengan attendance.view_photo. */
    @GetMapping("/api/attendance/{id}/photo/{kind}")
    public ResponseEntity<byte[]> photo(@PathVariable UUID id, @PathVariable String kind) {
        return service.photo(id, kind)
                .map(p -> ResponseEntity.ok().contentType(org.springframework.http.MediaType.parseMediaType(p.contentType()))
                        .header("Cache-Control", "private, max-age=300").body(p.image()))
                .orElseGet(() -> ResponseEntity.notFound().build());
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
