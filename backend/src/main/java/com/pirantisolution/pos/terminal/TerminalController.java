package com.pirantisolution.pos.terminal;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.terminal.TerminalDtos.CreateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.CreateTerminalRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.DeviceView;
import com.pirantisolution.pos.terminal.TerminalDtos.TerminalView;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateTerminalRequest;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class TerminalController {

    private final TerminalService service;
    private final IdempotencyService idempotency;

    public TerminalController(TerminalService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    @GetMapping("/api/terminals")
    public ResponseEntity<ApiResponse<List<TerminalView>>> list(@RequestParam(required = false) UUID outletId) {
        return Responses.ok(service.listTerminals(outletId));
    }

    @GetMapping("/api/terminals/{id}")
    public ResponseEntity<ApiResponse<TerminalView>> get(@PathVariable UUID id) {
        return Responses.ok(service.getTerminal(id));
    }

    @PostMapping("/api/terminals")
    public ResponseEntity<?> create(@Valid @RequestBody CreateTerminalRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/terminals", req,
                () -> Responses.created(service.createTerminal(req), "Terminal dibuat"));
    }

    @PutMapping("/api/terminals/{id}")
    public ResponseEntity<ApiResponse<TerminalView>> update(@PathVariable UUID id,
            @Valid @RequestBody UpdateTerminalRequest req) {
        return Responses.ok(service.updateTerminal(id, req), "Terminal diperbarui");
    }

    @GetMapping("/api/devices")
    public ResponseEntity<ApiResponse<List<DeviceView>>> devices(@RequestParam(required = false) UUID outletId) {
        return Responses.ok(service.listDevices(outletId));
    }

    @PostMapping("/api/devices")
    public ResponseEntity<?> createDevice(@Valid @RequestBody CreateDeviceRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/devices", req,
                () -> Responses.created(service.createDevice(req), "Device dibuat"));
    }

    @PutMapping("/api/devices/{id}")
    public ResponseEntity<ApiResponse<DeviceView>> updateDevice(@PathVariable UUID id,
            @Valid @RequestBody UpdateDeviceRequest req) {
        return Responses.ok(service.updateDevice(id, req), "Device diperbarui");
    }
}
