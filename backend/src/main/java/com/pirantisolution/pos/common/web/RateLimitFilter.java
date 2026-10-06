package com.pirantisolution.pos.common.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.config.PosProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Rate limiting fixed-window per menit.
 *
 * <p>TEMPORARY IMPLEMENTATION (ASSUMPTIONS B11): counter disimpan in-memory per instance.
 * Jika backend dijalankan lebih dari satu instance, limit efektif dikalikan jumlah instance.
 * Ganti dengan rate limiter terdistribusi (Redis / API gateway) sebelum scale-out.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class RateLimitFilter extends OncePerRequestFilter {

    private static final int MAX_TRACKED_KEYS = 50_000;

    private final PosProperties.RateLimit config;
    private final ObjectMapper objectMapper;
    private final Map<String, Window> windows = new ConcurrentHashMap<>();

    public RateLimitFilter(PosProperties properties, ObjectMapper objectMapper) {
        this.config = properties.rateLimit();
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !config.enabled() || !request.getRequestURI().startsWith("/api/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
            FilterChain chain) throws ServletException, IOException {
        // Endpoint yang memeriksa password (login dev & approval supervisor) memakai limit ketat.
        boolean authEndpoint = request.getRequestURI().startsWith("/api/dev-auth/")
                || request.getRequestURI().equals("/api/approvals")
                || request.getRequestURI().equals("/api/cashier/approvals");
        String key;
        int limit;
        if (authEndpoint) {
            key = "auth:" + request.getRemoteAddr();
            limit = config.authRequestsPerMinute();
        } else {
            String auth = request.getHeader("Authorization");
            key = auth != null && auth.startsWith("Bearer ")
                    ? "tok:" + sha256(auth.substring(7))
                    : "ip:" + request.getRemoteAddr();
            limit = config.requestsPerMinute();
        }

        if (!tryAcquire(key, limit)) {
            response.setStatus(ErrorCode.RATE_LIMITED.status().value());
            response.setHeader("Retry-After", "60");
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.setCharacterEncoding(StandardCharsets.UTF_8.name());
            objectMapper.writeValue(response.getOutputStream(), ApiResponse.error(
                    ErrorCode.RATE_LIMITED.name(), ErrorCode.RATE_LIMITED.defaultMessage(), null,
                    RequestContext.requestId()));
            return;
        }
        chain.doFilter(request, response);
    }

    boolean tryAcquire(String key, int limit) {
        long minute = System.currentTimeMillis() / 60_000L;
        if (windows.size() > MAX_TRACKED_KEYS) {
            windows.entrySet().removeIf(e -> e.getValue().minute < minute);
        }
        Window w = windows.compute(key, (k, existing) ->
                existing == null || existing.minute != minute ? new Window(minute) : existing);
        return w.count.incrementAndGet() <= limit;
    }

    private static String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest, 0, 16);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static final class Window {
        final long minute;
        final AtomicInteger count = new AtomicInteger();

        Window(long minute) {
            this.minute = minute;
        }
    }
}
