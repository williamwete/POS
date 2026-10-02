package com.pirantisolution.pos.common.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Filter terluar: memberi requestId, mengisi MDC, dan menulis satu access log terstruktur
 * per request (§68). Tidak pernah me-log header Authorization atau body.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestLoggingFilter extends OncePerRequestFilter {

    private static final Logger access = LoggerFactory.getLogger("pos.access");

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
            FilterChain chain) throws ServletException, IOException {
        long start = System.nanoTime();
        String requestId = RequestContext.sanitizeRequestId(request.getHeader(RequestContext.HEADER_REQUEST_ID));
        MDC.put(RequestContext.MDC_REQUEST_ID, requestId);
        putIfSafe(RequestContext.MDC_TERMINAL_ID, request.getHeader(RequestContext.HEADER_TERMINAL_ID));
        putIfSafe(RequestContext.MDC_OUTLET_ID, request.getHeader(RequestContext.HEADER_OUTLET_ID));
        response.setHeader(RequestContext.HEADER_REQUEST_ID, requestId);
        try {
            chain.doFilter(request, response);
        } finally {
            long durationMs = (System.nanoTime() - start) / 1_000_000;
            if (!request.getRequestURI().startsWith("/actuator")) {
                access.info("method={} endpoint={} status={} duration={}ms",
                        request.getMethod(), request.getRequestURI(), response.getStatus(), durationMs);
            }
            MDC.clear();
        }
    }

    private static void putIfSafe(String key, String value) {
        if (value != null && value.matches("^[A-Za-z0-9-]{1,64}$")) {
            MDC.put(key, value);
        }
    }
}
