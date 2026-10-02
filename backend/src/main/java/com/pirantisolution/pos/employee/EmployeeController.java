package com.pirantisolution.pos.employee;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.employee.EmployeeDtos.CreateEmployeeRequest;
import com.pirantisolution.pos.employee.EmployeeDtos.EmployeeView;
import com.pirantisolution.pos.employee.EmployeeDtos.UpdateEmployeeRequest;
import com.pirantisolution.pos.idempotency.IdempotencyService;
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
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/employees")
public class EmployeeController {

    private final EmployeeService service;
    private final IdempotencyService idempotency;

    public EmployeeController(EmployeeService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    @GetMapping
    public ResponseEntity<ApiResponse<List<EmployeeView>>> search(
            @RequestParam(required = false) UUID outletId,
            @RequestParam(required = false) String q,
            @RequestParam(required = false) Boolean active,
            @RequestParam(required = false) Integer limit) {
        return Responses.ok(service.search(outletId, q, active, limit));
    }

    @GetMapping("/{id}")
    public ResponseEntity<ApiResponse<EmployeeView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    @PostMapping
    public ResponseEntity<?> create(@Valid @RequestBody CreateEmployeeRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/employees", req,
                () -> Responses.created(service.create(req), "Karyawan dibuat"));
    }

    @PutMapping("/{id}")
    public ResponseEntity<ApiResponse<EmployeeView>> update(@PathVariable UUID id,
            @Valid @RequestBody UpdateEmployeeRequest req) {
        return Responses.ok(service.update(id, req), "Data karyawan diperbarui");
    }
}
