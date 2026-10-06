package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.config.PosProperties;
import java.util.Arrays;
import java.util.Set;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

@Configuration
public class OpenbravoConfig {

    private static final Set<String> SIMULATOR_PROFILES = Set.of("local", "test");

    @Bean
    OpenbravoClient openbravoClient(PosProperties properties, Environment environment, ObjectMapper json) {
        PosProperties.Openbravo cfg = properties.openbravo();
        PosProperties.OpenbravoMode mode = cfg == null || cfg.mode() == null ? PosProperties.OpenbravoMode.DISABLED : cfg.mode();
        return switch (mode) {
            case DISABLED -> new DisabledOpenbravoClient();
            case HTTP -> new HttpOpenbravoClient(cfg, json);
            case SIMULATOR -> {
                String[] active = environment.getActiveProfiles();
                boolean allowed = active.length > 0 && Arrays.stream(active).allMatch(SIMULATOR_PROFILES::contains);
                if (!allowed) {
                    throw new IllegalStateException(
                            "pos.openbravo.mode=SIMULATOR hanya diizinkan dengan profile local/test, aktif: "
                                    + Arrays.toString(active));
                }
                yield new SimulatorOpenbravoClient(json);
            }
        };
    }
}
