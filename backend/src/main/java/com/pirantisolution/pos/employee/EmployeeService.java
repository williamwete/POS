package com.pirantisolution.pos.employee;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.db.SystemTx;
import com.pirantisolution.pos.employee.EmployeeDtos.CreateEmployeeRequest;
import com.pirantisolution.pos.employee.EmployeeDtos.EmployeeView;
import com.pirantisolution.pos.employee.EmployeeDtos.UpdateEmployeeRequest;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class EmployeeService {

    static final String PERM_VIEW = "employee.view";
    static final String PERM_MANAGE = "employee.manage";

    private final EmployeeRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final SystemTx systemTx;

    public EmployeeService(EmployeeRepository repo, AccessService access, AuditService audit, SystemTx systemTx) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
        this.systemTx = systemTx;
    }

    /** Daftar karyawan yang terlihat oleh user (RLS: employee.view/manage per outlet). */
    @Transactional(readOnly = true)
    public List<EmployeeView> search(UUID outletId, String q, Boolean active, Integer limit) {
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        } else {
            access.currentUser();
        }
        int max = limit == null ? 100 : Math.min(Math.max(limit, 1), 500);
        return repo.search(outletId, q, active, max);
    }

    @Transactional(readOnly = true)
    public EmployeeView get(UUID id) {
        access.currentUser();
        return repo.findById(id).orElseThrow(() -> ApiException.notFound("Karyawan"));
    }

    @Transactional
    public EmployeeView create(CreateEmployeeRequest req) {
        access.requireScope(PERM_MANAGE, req.homeOutletId());
        CurrentUser cu = access.currentUser();
        UUID id = repo.insert(req, cu.userId());
        EmployeeView created = repo.findById(id).orElseThrow();
        audit.record(AuditEvent.of("EMPLOYEE_CREATED", "EMPLOYEE", id)
                .outlet(req.homeOutletId()).change(null, created));
        return created;
    }

    @Transactional
    public EmployeeView update(UUID id, UpdateEmployeeRequest req) {
        access.currentUser();
        EmployeeView before = repo.findById(id).orElseThrow(() -> ApiException.notFound("Karyawan"));
        // Pindah outlet butuh hak di outlet lama DAN outlet baru.
        access.requireScope(PERM_MANAGE, before.homeOutletId());
        if (!Objects.equals(before.homeOutletId(), req.homeOutletId())) {
            access.requireScope(PERM_MANAGE, req.homeOutletId());
        }
        if (before.active() && !req.active()
                && Boolean.TRUE.equals(systemTx.system(() -> repo.hasActiveLinkedUser(id)))) {
            throw ApiException.validation(
                    "Karyawan masih memiliki akun login aktif. Nonaktifkan akun user terlebih dahulu.");
        }
        CurrentUser cu = access.currentUser();
        Guards.requireUpdated(repo.update(id, req, cu.userId()));
        EmployeeView after = repo.findById(id).orElseThrow();
        String action = before.active() && !after.active() ? "EMPLOYEE_DEACTIVATED" : "EMPLOYEE_UPDATED";
        audit.record(AuditEvent.of(action, "EMPLOYEE", id).outlet(after.homeOutletId()).change(before, after));
        return after;
    }
}
