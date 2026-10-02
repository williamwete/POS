package com.pirantisolution.pos.settings;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.security.AccessService;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class SettingsService {
    private final JdbcClient jdbc;
    private final AccessService access;
    private final ObjectMapper objectMapper;

    public SettingsService(JdbcClient jdbc, AccessService access, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.access = access;
        this.objectMapper = objectMapper;
    }

    private record Row(String key, String value) {
    }

    @Transactional(readOnly = true)
    public Map<String, JsonNode> effective(UUID outletId) {
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        } else {
            access.currentUser();
        }
        List<Row> rows = jdbc.sql("""
                SELECT d.key, pos.get_setting(d.key, CAST(:o AS uuid))::text AS value
                FROM pos.setting_definitions d ORDER BY d.key
                """)
                .param("o", outletId)
                .query(Row.class).list();
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (Row r : rows) {
            try {
                result.put(r.key(), objectMapper.readTree(r.value()));
            } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
                throw new IllegalStateException("Invalid setting value for " + r.key(), e);
            }
        }
        return result;
    }
}
