package com.pirantisolution.pos.employee;

import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.employee.EmployeeDtos.CreateEmployeeRequest;
import com.pirantisolution.pos.employee.EmployeeDtos.EmployeeView;
import com.pirantisolution.pos.employee.EmployeeDtos.UpdateEmployeeRequest;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class EmployeeRepository {

    private static final String SELECT = """
            SELECT e.id, e.organization_id, e.employee_code, e.full_name, e.phone, e.email, e.position,
                   e.home_outlet_id, o.code AS home_outlet_code, e.hire_date, e.active,
                   u.id AS linked_user_id, u.username AS linked_username, e.version, e.updated_at
            FROM pos.employees e
            LEFT JOIN pos.outlets o ON o.id = e.home_outlet_id
            LEFT JOIN pos.users u ON u.employee_id = e.id
            """;

    private final JdbcClient jdbc;

    public EmployeeRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<EmployeeView> search(UUID outletId, String q, Boolean active, int limit) {
        String term = Guards.trimToNull(q);
        return jdbc.sql(SELECT + """
                WHERE (CAST(:outlet AS uuid) IS NULL OR e.home_outlet_id = CAST(:outlet AS uuid))
                  AND (CAST(:active AS boolean) IS NULL OR e.active = CAST(:active AS boolean))
                  AND (CAST(:q AS text) IS NULL
                       OR e.full_name ILIKE '%' || CAST(:q AS text) || '%'
                       OR e.employee_code ILIKE '%' || CAST(:q AS text) || '%')
                ORDER BY e.employee_code
                LIMIT :limit
                """)
                .param("outlet", outletId)
                .param("active", active)
                .param("q", term == null ? null : term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_"))
                .param("limit", limit)
                .query(EmployeeView.class).list();
    }

    public Optional<EmployeeView> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE e.id = :id").param("id", id).query(EmployeeView.class).optional();
    }

    public UUID insert(CreateEmployeeRequest req, UUID actorId) {
        return jdbc.sql("""
                INSERT INTO pos.employees (organization_id, employee_code, full_name, phone, email, position,
                                           home_outlet_id, hire_date, created_by, updated_by)
                VALUES (pos.current_org_id(), :code, :name, :phone, :email, :position,
                        CAST(:outlet AS uuid), CAST(:hire AS date), :actor, :actor)
                RETURNING id
                """)
                .param("code", req.employeeCode())
                .param("name", req.fullName().trim())
                .param("phone", Guards.trimToNull(req.phone()))
                .param("email", lower(req.email()))
                .param("position", Guards.trimToNull(req.position()))
                .param("outlet", req.homeOutletId())
                .param("hire", req.hireDate())
                .param("actor", actorId)
                .query(UUID.class).single();
    }

    public Optional<UUID> update(UUID id, UpdateEmployeeRequest req, UUID actorId) {
        return jdbc.sql("""
                UPDATE pos.employees
                SET full_name = :name, phone = :phone, email = :email, position = :position,
                    home_outlet_id = CAST(:outlet AS uuid), hire_date = CAST(:hire AS date),
                    active = :active, updated_by = :actor
                WHERE id = :id AND version = :version
                RETURNING id
                """)
                .param("name", req.fullName().trim())
                .param("phone", Guards.trimToNull(req.phone()))
                .param("email", lower(req.email()))
                .param("position", Guards.trimToNull(req.position()))
                .param("outlet", req.homeOutletId())
                .param("hire", req.hireDate())
                .param("active", req.active())
                .param("actor", actorId)
                .param("id", id)
                .param("version", req.version())
                .query(UUID.class).optional();
    }

    /** Dijalankan dalam konteks sistem: hanya mengembalikan boolean, tanpa membuka data user. */
    public boolean hasActiveLinkedUser(UUID employeeId) {
        return jdbc.sql("SELECT EXISTS (SELECT 1 FROM pos.users WHERE employee_id = :id AND active)")
                .param("id", employeeId).query(Boolean.class).single();
    }

    private static String lower(String email) {
        String t = Guards.trimToNull(email);
        return t == null ? null : t.toLowerCase();
    }
}
