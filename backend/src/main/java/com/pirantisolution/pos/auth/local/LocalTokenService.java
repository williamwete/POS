package com.pirantisolution.pos.auth.local;

import com.nimbusds.jose.jwk.source.ImmutableSecret;
import com.pirantisolution.pos.config.PosProperties;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

/**
 * Menerbitkan JWT berbentuk sama dengan Supabase (sub, role=authenticated,
 * aud=authenticated, email) untuk pengembangan lokal. TIDAK dipakai di staging/production.
 */
@Service
@Profile({"local", "test"})
@ConditionalOnProperty(name = "pos.auth.provider", havingValue = "LOCAL")
public class LocalTokenService {

    public record IssuedToken(String accessToken, String tokenType, long expiresIn) {
    }

    private final JwtEncoder encoder;
    private final PosProperties properties;

    public LocalTokenService(PosProperties properties) {
        this.properties = properties;
        byte[] secret = properties.jwt().hs256Secret().getBytes(StandardCharsets.UTF_8);
        SecretKey key = new SecretKeySpec(secret, "HmacSHA256");
        this.encoder = new NimbusJwtEncoder(new ImmutableSecret<>(key));
    }

    public IssuedToken issue(UUID authUserId, String email) {
        long ttl = properties.auth().localTokenTtlSeconds();
        Instant now = Instant.now();
        JwtClaimsSet.Builder claims = JwtClaimsSet.builder()
                .subject(authUserId.toString())
                .audience(List.of(properties.jwt().audience()))
                .issuedAt(now)
                .expiresAt(now.plusSeconds(ttl))
                .claim("role", "authenticated")
                .claim("email", email)
                // bentuk sama dengan Supabase: metode & waktu autentikasi (dipakai unlock terminal)
                .claim("amr", List.of(java.util.Map.of("method", "password", "timestamp", now.getEpochSecond())));
        if (StringUtils.hasText(properties.jwt().issuer())) {
            claims.issuer(properties.jwt().issuer());
        }
        JwsHeader header = JwsHeader.with(MacAlgorithm.HS256).build();
        String token = encoder.encode(JwtEncoderParameters.from(header, claims.build())).getTokenValue();
        return new IssuedToken(token, "bearer", ttl);
    }
}
