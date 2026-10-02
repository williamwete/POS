package com.pirantisolution.pos.common.api;

import com.pirantisolution.pos.common.web.RequestContext;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

/**
 * Helper untuk membuat response envelope dari controller.
 */
public final class Responses {

    private Responses() {
    }

    public static <T> ResponseEntity<ApiResponse<T>> ok(T data) {
        return ResponseEntity.ok(ApiResponse.ok(data, null, RequestContext.requestId()));
    }

    public static <T> ResponseEntity<ApiResponse<T>> ok(T data, String message) {
        return ResponseEntity.ok(ApiResponse.ok(data, message, RequestContext.requestId()));
    }

    public static <T> ResponseEntity<ApiResponse<T>> created(T data, String message) {
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(ApiResponse.ok(data, message, RequestContext.requestId()));
    }
}
