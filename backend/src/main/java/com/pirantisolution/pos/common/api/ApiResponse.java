package com.pirantisolution.pos.common.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;

/**
 * Envelope response standar (§62).
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ApiResponse<T>(
        boolean success,
        T data,
        String message,
        String errorCode,
        List<FieldError> details,
        String requestId) {

    public record FieldError(String field, String message) {
    }

    public static <T> ApiResponse<T> ok(T data, String message, String requestId) {
        return new ApiResponse<>(true, data, message, null, null, requestId);
    }

    public static <T> ApiResponse<T> error(String errorCode, String message, List<FieldError> details,
            String requestId) {
        return new ApiResponse<>(false, null, message, errorCode, details, requestId);
    }
}
