package com.pirantisolution.pos.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.web.RequestContext;
import com.pirantisolution.pos.config.PosProperties;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimNames;
import org.springframework.security.oauth2.jwt.JwtClaimValidator;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.web.authentication.BearerTokenAuthenticationFilter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.util.StringUtils;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http, ObjectMapper objectMapper) throws Exception {
        http
                .csrf(csrf -> csrf.disable()) // API stateless dengan bearer token, tanpa cookie sesi
                .cors(cors -> { })
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .httpBasic(b -> b.disable())
                .formLogin(f -> f.disable())
                .logout(l -> l.disable())
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        .requestMatchers("/error").permitAll()
                        .requestMatchers("/actuator/health", "/actuator/health/**", "/actuator/info").permitAll()
                        // controller hanya ada pada profile local (DevAuthController)
                        .requestMatchers(HttpMethod.POST, "/api/dev-auth/token").permitAll()
                        // callback penyedia pembayaran: tanpa login, diverifikasi tanda tangan HMAC (PaymentService)
                        .requestMatchers(HttpMethod.POST, "/api/payments/callback/*").permitAll()
                        .requestMatchers("/api/**").authenticated()
                        .anyRequest().denyAll())
                .oauth2ResourceServer(rs -> rs
                        .jwt(jwt -> { })
                        .authenticationEntryPoint((req, res, ex) ->
                                writeError(res, objectMapper, ErrorCode.UNAUTHENTICATED))
                        .accessDeniedHandler((req, res, ex) ->
                                writeError(res, objectMapper, ErrorCode.USER_NOT_AUTHORIZED)))
                .exceptionHandling(e -> e
                        .authenticationEntryPoint((req, res, ex) ->
                                writeError(res, objectMapper, ErrorCode.UNAUTHENTICATED))
                        .accessDeniedHandler((req, res, ex) ->
                                writeError(res, objectMapper, ErrorCode.USER_NOT_AUTHORIZED)))
                .addFilterAfter(new MdcUserFilter(), BearerTokenAuthenticationFilter.class);
        return http.build();
    }

    /**
     * Validasi JWT Supabase Auth. Mendukung JWKS (ES256/RS256) atau legacy HS256 secret.
     */
    @Bean
    JwtDecoder jwtDecoder(PosProperties properties) {
        PosProperties.Jwt cfg = properties.jwt();
        if (cfg == null) {
            throw new IllegalStateException("pos.jwt.* configuration is required");
        }
        NimbusJwtDecoder decoder;
        if (StringUtils.hasText(cfg.jwkSetUri())) {
            decoder = NimbusJwtDecoder.withJwkSetUri(cfg.jwkSetUri())
                    .jwsAlgorithm(SignatureAlgorithm.ES256)
                    .jwsAlgorithm(SignatureAlgorithm.RS256)
                    .build();
        } else if (StringUtils.hasText(cfg.hs256Secret())) {
            byte[] secret = cfg.hs256Secret().getBytes(StandardCharsets.UTF_8);
            if (secret.length < 32) {
                throw new IllegalStateException("pos.jwt.hs256-secret must be at least 32 bytes");
            }
            SecretKey key = new SecretKeySpec(secret, "HmacSHA256");
            decoder = NimbusJwtDecoder.withSecretKey(key).macAlgorithm(MacAlgorithm.HS256).build();
        } else {
            throw new IllegalStateException("Set pos.jwt.jwk-set-uri or pos.jwt.hs256-secret");
        }

        OAuth2TokenValidator<Jwt> base = StringUtils.hasText(cfg.issuer())
                ? JwtValidators.createDefaultWithIssuer(cfg.issuer())
                : JwtValidators.createDefault();
        OAuth2TokenValidator<Jwt> audience = new JwtClaimValidator<List<String>>(JwtClaimNames.AUD,
                aud -> aud != null && aud.contains(cfg.audience()));
        OAuth2TokenValidator<Jwt> role = new JwtClaimValidator<String>("role", "authenticated"::equals);
        OAuth2TokenValidator<Jwt> subject = new JwtClaimValidator<String>(JwtClaimNames.SUB,
                StringUtils::hasText);
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(base, audience, role, subject));
        return decoder;
    }

    @Bean
    CorsConfigurationSource corsConfigurationSource(PosProperties properties) {
        CorsConfiguration cors = new CorsConfiguration();
        cors.setAllowedOrigins(properties.cors().allowedOrigins());
        cors.setAllowedMethods(List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        cors.setAllowedHeaders(List.of("Authorization", "Content-Type", "Idempotency-Key",
                RequestContext.HEADER_REQUEST_ID, RequestContext.HEADER_DEVICE_ID,
                RequestContext.HEADER_TERMINAL_ID, RequestContext.HEADER_OUTLET_ID));
        cors.setExposedHeaders(List.of(RequestContext.HEADER_REQUEST_ID, "Idempotent-Replayed"));
        cors.setAllowCredentials(false);
        cors.setMaxAge(3600L);
        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/api/**", cors);
        return source;
    }

    private static void writeError(HttpServletResponse res, ObjectMapper mapper, ErrorCode code)
            throws IOException {
        res.setStatus(code.status().value());
        res.setContentType(MediaType.APPLICATION_JSON_VALUE);
        res.setCharacterEncoding(StandardCharsets.UTF_8.name());
        mapper.writeValue(res.getOutputStream(),
                ApiResponse.error(code.name(), code.defaultMessage(), null, RequestContext.requestId()));
    }
}
