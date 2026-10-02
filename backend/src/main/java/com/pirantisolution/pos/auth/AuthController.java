package com.pirantisolution.pos.auth;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @GetMapping("/me")
    public ResponseEntity<ApiResponse<MeResponse>> me() {
        return Responses.ok(authService.me());
    }

    @PostMapping("/session")
    public ResponseEntity<ApiResponse<MeResponse>> startSession() {
        authService.startSession();
        return Responses.ok(authService.me(), "Login berhasil");
    }

    @PostMapping("/logout")
    public ResponseEntity<ApiResponse<Void>> logout() {
        authService.endSession();
        return Responses.ok(null, "Logout berhasil");
    }
}
