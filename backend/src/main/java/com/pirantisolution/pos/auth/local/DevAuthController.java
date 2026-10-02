package com.pirantisolution.pos.auth.local;

import com.pirantisolution.pos.auth.provider.LocalAuthAdmin;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Pengganti Supabase Auth untuk pengembangan lokal saja.
 * Di staging/production frontend login langsung ke Supabase Auth.
 */
@RestController
@RequestMapping("/api/dev-auth")
@Profile({"local", "test"})
@ConditionalOnProperty(name = "pos.auth.provider", havingValue = "LOCAL")
public class DevAuthController {

    private static final Logger log = LoggerFactory.getLogger(DevAuthController.class);

    public record TokenRequest(
            @NotBlank @Email @Size(max = 254) String email,
            @NotBlank @Size(max = 128) String password) {
    }

    private final LocalAuthAdmin authAdmin;
    private final LocalTokenService tokens;

    public DevAuthController(LocalAuthAdmin authAdmin, LocalTokenService tokens) {
        this.authAdmin = authAdmin;
        this.tokens = tokens;
    }

    @PostMapping("/token")
    public ResponseEntity<ApiResponse<LocalTokenService.IssuedToken>> token(@Valid @RequestBody TokenRequest request) {
        UUID authUserId = authAdmin.verify(request.email(), request.password());
        if (authUserId == null) {
            log.info("Local login failed");
            throw new ApiException(ErrorCode.INVALID_CREDENTIALS);
        }
        return Responses.ok(tokens.issue(authUserId, request.email().toLowerCase()));
    }
}
