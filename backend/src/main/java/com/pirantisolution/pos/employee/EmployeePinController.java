package com.pirantisolution.pos.employee;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** PIN verifikasi clock in/out. Hanya role dengan employee.reset_pin yang dapat mengatur/mereset. */
@RestController
public class EmployeePinController {

    public record SetPinRequest(@NotBlank String pin) {
    }

    private final JdbcClient jdbc;
    private final AuditService audit;

    public EmployeePinController(JdbcClient jdbc, AuditService audit) {
        this.jdbc = jdbc;
        this.audit = audit;
    }

    @PutMapping("/api/employees/{id}/pin")
    @Transactional
    public ResponseEntity<ApiResponse<Map<String, Object>>> set(@PathVariable UUID id, @Valid @RequestBody SetPinRequest req) {
        jdbc.sql("SELECT pos.set_employee_pin(:e, :p)").param("e", id).param("p", req.pin().trim()).query().singleRow();
        // nilai PIN tidak pernah masuk audit log
        audit.record(AuditEvent.of("EMPLOYEE_PIN_SET", "EMPLOYEE", id).change(null, Map.of("pinSet", true)));
        return Responses.ok(Map.of("hasPin", true));
    }

    @GetMapping("/api/employees/{id}/pin")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<Map<String, Object>>> status(@PathVariable UUID id) {
        Boolean has = jdbc.sql("SELECT pos.employee_has_pin(:e)").param("e", id).query(Boolean.class).single();
        return Responses.ok(Map.of("hasPin", Boolean.TRUE.equals(has)));
    }
}
