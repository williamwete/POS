package com.pirantisolution.pos.auth.local;

import com.pirantisolution.pos.config.PosProperties;
import jakarta.annotation.PostConstruct;
import java.util.Arrays;
import java.util.Set;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

/**
 * Pengaman: provider login LOCAL (shim + endpoint token dev) hanya boleh hidup pada
 * profile local/test. Aplikasi menolak start jika dikonfigurasi lain.
 */
@Component
public class LocalProfileGuard {

    private static final Set<String> ALLOWED = Set.of("local", "test");

    private final Environment environment;
    private final PosProperties properties;

    public LocalProfileGuard(Environment environment, PosProperties properties) {
        this.environment = environment;
        this.properties = properties;
    }

    @PostConstruct
    void verify() {
        boolean localProvider = properties.auth() != null
                && properties.auth().provider() == PosProperties.AuthProvider.LOCAL;
        if (!localProvider) {
            return;
        }
        String[] active = environment.getActiveProfiles();
        boolean onlyAllowed = active.length > 0 && Arrays.stream(active).allMatch(ALLOWED::contains);
        if (!onlyAllowed) {
            throw new IllegalStateException(
                    "pos.auth.provider=LOCAL hanya diizinkan dengan profile local/test, aktif: "
                            + Arrays.toString(active));
        }
    }
}
