package com.pirantisolution.pos.user;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.user.UserDtos.CreateUserRequest;
import com.pirantisolution.pos.user.UserDtos.ResetPasswordRequest;
import com.pirantisolution.pos.user.UserDtos.SetOutletsRequest;
import com.pirantisolution.pos.user.UserDtos.SetRolesRequest;
import com.pirantisolution.pos.user.UserDtos.UpdateUserRequest;
import com.pirantisolution.pos.user.UserDtos.UserView;
import jakarta.validation.Valid;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/users")
public class UserController {

    private final UserService service;
    private final IdempotencyService idempotency;

    public UserController(UserService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    @GetMapping
    public ResponseEntity<ApiResponse<List<UserView>>> list(@RequestParam(required = false) String q,
            @RequestParam(required = false) Boolean active) {
        return Responses.ok(service.list(q, active));
    }

    @GetMapping("/{id}")
    public ResponseEntity<ApiResponse<UserView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    @PostMapping
    public ResponseEntity<?> create(@Valid @RequestBody CreateUserRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        // Password tidak ikut dalam hash idempotency agar tidak tersimpan dalam bentuk turunan apa pun.
        Map<String, Object> fingerprint = new LinkedHashMap<>();
        fingerprint.put("username", req.username());
        fingerprint.put("email", req.email());
        fingerprint.put("displayName", req.displayName());
        fingerprint.put("employeeId", req.employeeId());
        fingerprint.put("roles", req.roles());
        fingerprint.put("outletIds", req.outletIds());
        return idempotency.execute(key, "POST", "/api/users", fingerprint,
                () -> Responses.created(service.create(req), "User dibuat"));
    }

    @PutMapping("/{id}")
    public ResponseEntity<ApiResponse<UserView>> update(@PathVariable UUID id,
            @Valid @RequestBody UpdateUserRequest req) {
        return Responses.ok(service.update(id, req), "User diperbarui");
    }

    @PutMapping("/{id}/roles")
    public ResponseEntity<ApiResponse<UserView>> setRoles(@PathVariable UUID id,
            @Valid @RequestBody SetRolesRequest req) {
        return Responses.ok(service.setRoles(id, req.roles()), "Role diperbarui");
    }

    @PutMapping("/{id}/outlets")
    public ResponseEntity<ApiResponse<UserView>> setOutlets(@PathVariable UUID id,
            @Valid @RequestBody SetOutletsRequest req) {
        return Responses.ok(service.setOutlets(id, req.outletIds()), "Akses outlet diperbarui");
    }

    @PostMapping("/{id}/reset-password")
    public ResponseEntity<ApiResponse<Void>> resetPassword(@PathVariable UUID id,
            @Valid @RequestBody ResetPasswordRequest req) {
        service.resetPassword(id, req.password());
        return Responses.ok(null, "Password direset");
    }
}
