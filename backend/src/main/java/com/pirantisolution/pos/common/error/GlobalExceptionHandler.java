package com.pirantisolution.pos.common.error;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.web.RequestContext;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

/**
 * Centralized exception handling (§99). Tidak pernah mengembalikan stack trace / pesan SQL ke client.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    /** Pesan RAISE dari trigger/fungsi DB berformat "KODE: detail". */
    private static final Pattern DB_ERROR_CODE = Pattern.compile("^([A-Z_]{3,64}):");

    /** Constraint unik -> pesan untuk user. */
    private static final Map<String, String> UNIQUE_MESSAGES = Map.ofEntries(
            Map.entry("organizations_code_uk", "Kode organisasi sudah dipakai"),
            Map.entry("outlets_org_code_uk", "Kode outlet sudah dipakai"),
            Map.entry("warehouses_org_code_uk", "Kode warehouse sudah dipakai"),
            Map.entry("devices_outlet_code_uk", "Kode device sudah dipakai di outlet ini"),
            Map.entry("terminals_code_uk", "Kode terminal sudah dipakai"),
            Map.entry("terminals_active_device_uk", "Device sudah terikat ke terminal aktif lain"),
            Map.entry("employees_org_code_uk", "Kode karyawan sudah dipakai"),
            Map.entry("users_username_uk", "Username sudah dipakai"),
            Map.entry("users_email_uk", "Email sudah dipakai"),
            Map.entry("users_employee_uk", "Karyawan sudah terhubung ke akun lain"),
            Map.entry("users_auth_user_uk", "Akun login sudah terhubung ke user lain"),
            Map.entry("roles_code_uk", "Kode role sudah dipakai"),
            Map.entry("user_roles_scope_uk", "Role sudah diberikan pada scope ini"),
            Map.entry("attendance_open_per_employee_uk", "Anda sudah clock in dan belum clock out"),
            Map.entry("attendance_breaks_open_uk", "Anda sedang istirahat"),
            Map.entry("cashier_sessions_active_terminal_uk", "Terminal sudah memiliki cashier session aktif"),
            Map.entry("cashier_sessions_active_employee_uk", "Anda masih memiliki cashier session aktif"),
            Map.entry("cash_count_items_uk", "Denominasi yang sama dikirim lebih dari sekali"));

    /** Constraint unik yang punya kode error bisnis sendiri. */
    private static final Map<String, ErrorCode> UNIQUE_CODES = Map.of(
            "users_employee_uk", ErrorCode.EMPLOYEE_ALREADY_LINKED,
            "attendance_open_per_employee_uk", ErrorCode.ATTENDANCE_ALREADY_OPEN,
            "attendance_breaks_open_uk", ErrorCode.ALREADY_ON_BREAK,
            "cashier_sessions_active_terminal_uk", ErrorCode.TERMINAL_ALREADY_OPEN,
            "cashier_sessions_active_employee_uk", ErrorCode.CASHIER_SESSION_ALREADY_OPEN,
            "cash_count_items_uk", ErrorCode.VALIDATION_FAILED);

    @ExceptionHandler(ApiException.class)
    ResponseEntity<ApiResponse<Void>> handleApi(ApiException ex) {
        return build(ex.code(), ex.getMessage(), null);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    ResponseEntity<ApiResponse<Void>> handleValidation(MethodArgumentNotValidException ex) {
        List<ApiResponse.FieldError> details = ex.getBindingResult().getFieldErrors().stream()
                .map(f -> new ApiResponse.FieldError(f.getField(), f.getDefaultMessage()))
                .toList();
        return build(ErrorCode.VALIDATION_FAILED, ErrorCode.VALIDATION_FAILED.defaultMessage(), details);
    }

    @ExceptionHandler(HandlerMethodValidationException.class)
    ResponseEntity<ApiResponse<Void>> handleMethodValidation(HandlerMethodValidationException ex) {
        List<ApiResponse.FieldError> details = ex.getAllErrors().stream()
                .map(e -> new ApiResponse.FieldError(null, e.getDefaultMessage()))
                .toList();
        return build(ErrorCode.VALIDATION_FAILED, ErrorCode.VALIDATION_FAILED.defaultMessage(), details);
    }

    @ExceptionHandler({
            MissingRequestHeaderException.class,
            MissingServletRequestParameterException.class,
            MethodArgumentTypeMismatchException.class})
    ResponseEntity<ApiResponse<Void>> handleBadParam(Exception ex) {
        return build(ErrorCode.VALIDATION_FAILED, "Parameter request tidak valid", null);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    ResponseEntity<ApiResponse<Void>> handleUnreadable(HttpMessageNotReadableException ex) {
        return build(ErrorCode.MALFORMED_REQUEST, ErrorCode.MALFORMED_REQUEST.defaultMessage(), null);
    }

    @ExceptionHandler(AccessDeniedException.class)
    ResponseEntity<ApiResponse<Void>> handleAccessDenied(AccessDeniedException ex) {
        return build(ErrorCode.USER_NOT_AUTHORIZED, ErrorCode.USER_NOT_AUTHORIZED.defaultMessage(), null);
    }

    @ExceptionHandler({NoResourceFoundException.class, HttpRequestMethodNotSupportedException.class})
    ResponseEntity<ApiResponse<Void>> handleNoResource(Exception ex) {
        return build(ErrorCode.NOT_FOUND, "Endpoint tidak ditemukan", null);
    }

    @ExceptionHandler(DataAccessException.class)
    ResponseEntity<ApiResponse<Void>> handleDataAccess(DataAccessException ex) {
        PSQLException pg = findPsql(ex);
        if (pg == null) {
            log.error("Database error", ex);
            return build(ErrorCode.INTERNAL_ERROR, ErrorCode.INTERNAL_ERROR.defaultMessage(), null);
        }
        String state = pg.getSQLState();
        ServerErrorMessage server = pg.getServerErrorMessage();
        String constraint = server != null ? server.getConstraint() : null;
        String message = server != null && server.getMessage() != null ? server.getMessage() : "";

        if ("42501".equals(state)) {
            // permission denied / RLS violation: berarti cek di service terlewat -> perlu diselidiki.
            log.warn("Database denied access (RLS/privilege): {}", message);
            return build(ErrorCode.USER_NOT_AUTHORIZED, ErrorCode.USER_NOT_AUTHORIZED.defaultMessage(), null);
        }
        if ("23505".equals(state)) {
            String msg = constraint != null
                    ? UNIQUE_MESSAGES.getOrDefault(constraint, ErrorCode.DUPLICATE_VALUE.defaultMessage())
                    : ErrorCode.DUPLICATE_VALUE.defaultMessage();
            ErrorCode code = constraint != null
                    ? UNIQUE_CODES.getOrDefault(constraint, ErrorCode.DUPLICATE_VALUE) : ErrorCode.DUPLICATE_VALUE;
            return build(code, msg, null);
        }
        if ("23503".equals(state)) {
            if (constraint != null && constraint.startsWith("terminals_")) {
                return build(ErrorCode.INVALID_DEVICE,
                        "Device harus berada di outlet yang sama dan bertipe sesuai", null);
            }
            return build(ErrorCode.VALIDATION_FAILED, "Referensi data tidak valid", null);
        }
        if ("23514".equals(state) || "22P02".equals(state) || "22001".equals(state)) {
            return build(ErrorCode.VALIDATION_FAILED, ErrorCode.VALIDATION_FAILED.defaultMessage(), null);
        }
        if ("P0001".equals(state)) {
            Matcher m = DB_ERROR_CODE.matcher(message);
            if (m.find()) {
                ErrorCode mapped = mapDbCode(m.group(1));
                if (mapped != null) {
                    return build(mapped, mapped.defaultMessage(), null);
                }
            }
        }
        log.error("Unhandled database error state={} constraint={}", state, constraint, ex);
        return build(ErrorCode.INTERNAL_ERROR, ErrorCode.INTERNAL_ERROR.defaultMessage(), null);
    }

    @ExceptionHandler(Exception.class)
    ResponseEntity<ApiResponse<Void>> handleUnexpected(Exception ex) {
        log.error("Unexpected error", ex);
        return build(ErrorCode.INTERNAL_ERROR, ErrorCode.INTERNAL_ERROR.defaultMessage(), null);
    }

    private static ErrorCode mapDbCode(String dbCode) {
        return switch (dbCode) {
            case "SYSTEM_ROLE_PROTECTED" -> ErrorCode.SYSTEM_ROLE_PROTECTED;
            case "SETTING_VALUE_INVALID", "SETTING_SCOPE_INVALID", "SETTING_UNKNOWN" -> ErrorCode.SETTING_INVALID;
            case "OUTLET_NOT_FOUND" -> ErrorCode.NOT_FOUND;
            case "APPEND_ONLY_VIOLATION" -> ErrorCode.USER_NOT_AUTHORIZED;
            case "BREAK_IN_PROGRESS" -> ErrorCode.BREAK_IN_PROGRESS;
            case "ATTENDANCE_CLOSED", "BREAK_CLOSED" -> ErrorCode.ATTENDANCE_CLOSED;
            case "ATTENDANCE_NOT_WORKING" -> ErrorCode.ALREADY_ON_BREAK;
            case "ATTENDANCE_INVALID_TRANSITION", "ATTENDANCE_IMMUTABLE_FIELD", "BREAK_IMMUTABLE_FIELD",
                    "BREAK_INVALID_UPDATE" -> ErrorCode.CONCURRENT_MODIFICATION;
            case "CASHIER_SESSION_OPEN" -> ErrorCode.CASHIER_SESSION_OPEN;
            case "CASHIER_SESSION_CLOSED" -> ErrorCode.CASHIER_SESSION_CLOSED;
            case "CASHIER_SESSION_LOCKED" -> ErrorCode.CASHIER_SESSION_LOCKED;
            case "CASHIER_SESSION_HAS_ACTIVITY" -> ErrorCode.CASHIER_SESSION_HAS_ACTIVITY;
            case "CASHIER_SESSION_NOT_OWNER" -> ErrorCode.USER_NOT_AUTHORIZED;
            case "ATTENDANCE_REQUIRED" -> ErrorCode.ATTENDANCE_REQUIRED;
            case "TERMINAL_INACTIVE" -> ErrorCode.TERMINAL_INACTIVE;
            case "REAUTH_REQUIRED" -> ErrorCode.REAUTH_REQUIRED;
            case "DENOMINATION_INVALID" -> ErrorCode.DENOMINATION_INVALID;
            case "OPENING_CASH_MISMATCH" -> ErrorCode.OPENING_CASH_MISMATCH;
            case "CASHIER_SESSION_INVALID_TRANSITION", "CASHIER_SESSION_IMMUTABLE_FIELD",
                    "CASHIER_SESSION_LOCK_REASON_REQUIRED", "CASH_COUNT_IMMUTABLE",
                    "CASH_COUNT_TYPE_NOT_ENABLED" -> ErrorCode.CONCURRENT_MODIFICATION;
            default -> null;
        };
    }

    private static PSQLException findPsql(Throwable ex) {
        Throwable t = ex;
        while (t != null) {
            if (t instanceof PSQLException p) {
                return p;
            }
            if (t instanceof SQLException sql && sql.getNextException() instanceof PSQLException p) {
                return p;
            }
            t = t.getCause();
        }
        return null;
    }

    private static ResponseEntity<ApiResponse<Void>> build(ErrorCode code, String message,
            List<ApiResponse.FieldError> details) {
        return ResponseEntity.status(code.status())
                .body(ApiResponse.error(code.name(), message, details, RequestContext.requestId()));
    }
}
