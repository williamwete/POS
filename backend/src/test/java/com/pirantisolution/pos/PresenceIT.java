package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Base64;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 10a — clock in/out wajib PIN + foto, PIN terkunci setelah 5 kali salah, hak lihat foto. */
@TestPropertySource(properties = "pos.attendance.enforce-verification=true")
class PresenceIT extends IntegrationTestBase {

    private static final String JPEG = "data:image/jpeg;base64,"
            + Base64.getEncoder().encodeToString(new byte[] {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0, 1, 2, 3});

    private MvcResult putToken(String token, String url, Object body) throws Exception {
        return mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put(url)
                .header("Authorization", "Bearer " + token)
                .contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body))).andReturn();
    }

    private void setPin(Cashier c, String pin) throws Exception {
        MvcResult r = putAs("supervisor.jkt", "/api/employees/" + c.employeeId() + "/pin", Map.of("pin", pin));
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(200);
    }

    @Test
    void clockInNeedsPinAndPhotoAndLocksAfterFiveWrongPins() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        Map<String, Object> noProof = Map.of("outletId", OUTLET_JKT);
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in", noProof))).isEqualTo("PIN_REQUIRED");
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT, "pin", "123456"))))
                .isEqualTo("PHOTO_REQUIRED");
        // PIN belum diatur
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in",
                Map.of("outletId", OUTLET_JKT, "pin", "123456", "photo", JPEG)))).isEqualTo("PIN_NOT_SET");

        // kasir tidak boleh mengatur PIN; supervisor boleh; PIN harus 6 digit
        assertThat(putToken(c.token(), "/api/employees/" + c.employeeId() + "/pin", Map.of("pin", "123456"))
                .getResponse().getStatus()).isEqualTo(403);
        assertThat(code(putAs("supervisor.jkt", "/api/employees/" + c.employeeId() + "/pin", Map.of("pin", "12ab"))))
                .isEqualTo("PIN_FORMAT_INVALID");
        setPin(c, "246810");

        // foto bukan JPEG ditolak tanpa menghitung percobaan PIN
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in",
                Map.of("outletId", OUTLET_JKT, "pin", "246810", "photo", "data:image/jpeg;base64,aGVsbG8="))))
                .isEqualTo("PHOTO_INVALID");

        for (int i = 4; i >= 1; i--) {
            MvcResult wrong = call(c.token(), "POST", "/api/attendance/clock-in",
                    Map.of("outletId", OUTLET_JKT, "pin", "000000", "photo", JPEG));
            assertThat(code(wrong)).isEqualTo("PIN_INVALID");
            assertThat(wrong.getResponse().getContentAsString()).contains("Sisa percobaan: " + i);
        }
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in",
                Map.of("outletId", OUTLET_JKT, "pin", "000000", "photo", JPEG)))).isEqualTo("PIN_LOCKED");
        // PIN benar pun ditolak saat terkunci; supervisor mereset PIN membuka kunci
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-in",
                Map.of("outletId", OUTLET_JKT, "pin", "246810", "photo", JPEG)))).isEqualTo("PIN_LOCKED");
        setPin(c, "135790");

        MvcResult ok = call(c.token(), "POST", "/api/attendance/clock-in",
                Map.of("outletId", OUTLET_JKT, "pin", "135790", "photo", JPEG));
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(201);
        String attendanceId = body(ok).at("/data/id").asText();

        // foto: pemilik & supervisor outlet boleh; kasir outlet lain tidak
        assertThat(call(c.token(), "GET", "/api/attendance/" + attendanceId + "/photo/CLOCK_IN", null).getResponse().getStatus()).isEqualTo(200);
        assertThat(getAs("supervisor.jkt", "/api/attendance/" + attendanceId + "/photo/CLOCK_IN").getResponse().getStatus()).isEqualTo(200);
        assertThat(call(newCashier(OUTLET_BDG).token(), "GET", "/api/attendance/" + attendanceId + "/photo/CLOCK_IN", null)
                .getResponse().getStatus()).isEqualTo(404);

        // clock out juga wajib PIN + foto
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-out", Map.of()))).isEqualTo("PIN_REQUIRED");
        assertThat(call(c.token(), "POST", "/api/attendance/clock-out", Map.of("pin", "135790", "photo", JPEG))
                .getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void menusFollowRoleDefaultsAndOwnerCanOverride() throws Exception {
        JsonNode cashierMenus = body(call(newCashier(OUTLET_JKT).token(), "GET", "/api/menus/me?outletId=" + OUTLET_JKT, null)).get("data");
        java.util.List<String> codes = new java.util.ArrayList<>();
        cashierMenus.forEach(m -> codes.add(m.get("code").asText()));
        assertThat(codes).containsExactly("pos", "clock", "beginning-cash", "product-list", "history", "closing");

        assertThat(call(newCashier(OUTLET_JKT).token(), "GET", "/api/admin/menus", null).getResponse().getStatus()).isEqualTo(403);
        assertThat(body(getAs("owner", "/api/admin/menus")).get("data").size()).isEqualTo(44);

        MvcResult set = putAs("owner", "/api/admin/menus", Map.of("menuCode", "history", "roleCode", "SUPERVISOR", "enabled", false));
        assertThat(set.getResponse().getStatus()).as(set.getResponse().getContentAsString()).isEqualTo(200);
        java.util.List<String> sup = new java.util.ArrayList<>();
        body(getAs("supervisor.jkt", "/api/menus/me?outletId=" + OUTLET_JKT)).get("data").forEach(m -> sup.add(m.get("code").asText()));
        assertThat(sup).doesNotContain("history");
        // reset ke default
        putAs("owner", "/api/admin/menus", java.util.Map.of("menuCode", "history", "roleCode", "SUPERVISOR"));
        sup.clear();
        body(getAs("supervisor.jkt", "/api/menus/me?outletId=" + OUTLET_JKT)).get("data").forEach(m -> sup.add(m.get("code").asText()));
        assertThat(sup).contains("history");
        assertThat(code(putAs("owner", "/api/admin/menus", Map.of("menuCode", "pos", "roleCode", "SUPER_ADMIN", "enabled", true))))
                .isEqualTo("MENU_ROLE_NOT_CONFIGURABLE");
    }
}
