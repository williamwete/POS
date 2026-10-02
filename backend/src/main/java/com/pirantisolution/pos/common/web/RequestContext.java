package com.pirantisolution.pos.common.web;

import jakarta.servlet.http.HttpServletRequest;
import java.util.UUID;
import java.util.regex.Pattern;
import org.slf4j.MDC;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/**
 * Metadata request (requestId, IP, device, terminal) yang dipakai logging dan audit.
 * Header device/terminal/outlet dari client hanya untuk jejak audit, BUKAN untuk otorisasi.
 */
public final class RequestContext {

    public static final String MDC_REQUEST_ID = "requestId";
    public static final String MDC_USER_ID = "userId";
    public static final String MDC_TERMINAL_ID = "terminalId";
    public static final String MDC_OUTLET_ID = "outletId";

    public static final String HEADER_REQUEST_ID = "X-Request-Id";
    public static final String HEADER_DEVICE_ID = "X-Device-Id";
    public static final String HEADER_TERMINAL_ID = "X-Terminal-Id";
    public static final String HEADER_OUTLET_ID = "X-Outlet-Id";

    private static final Pattern SAFE_TOKEN = Pattern.compile("^[A-Za-z0-9._:-]{1,128}$");

    private RequestContext() {
    }

    public static String requestId() {
        String id = MDC.get(MDC_REQUEST_ID);
        return id != null ? id : "no-request";
    }

    public static String clientIp() {
        HttpServletRequest req = current();
        return req != null ? req.getRemoteAddr() : null;
    }

    public static String deviceId() {
        return safeHeader(HEADER_DEVICE_ID);
    }

    public static UUID terminalId() {
        return uuidHeader(HEADER_TERMINAL_ID);
    }

    public static UUID outletId() {
        return uuidHeader(HEADER_OUTLET_ID);
    }

    /** Nilai header yang aman untuk disimpan/log; selain itu diabaikan. */
    public static String safeHeader(String name) {
        HttpServletRequest req = current();
        if (req == null) {
            return null;
        }
        String v = req.getHeader(name);
        return v != null && SAFE_TOKEN.matcher(v).matches() ? v : null;
    }

    public static String sanitizeRequestId(String candidate) {
        if (candidate != null && candidate.length() >= 8 && SAFE_TOKEN.matcher(candidate).matches()) {
            return candidate;
        }
        return UUID.randomUUID().toString();
    }

    private static UUID uuidHeader(String name) {
        String v = safeHeader(name);
        if (v == null) {
            return null;
        }
        try {
            return UUID.fromString(v);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static HttpServletRequest current() {
        if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attrs) {
            return attrs.getRequest();
        }
        return null;
    }
}
