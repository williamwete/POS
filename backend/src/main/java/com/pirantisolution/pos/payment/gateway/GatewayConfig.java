package com.pirantisolution.pos.payment.gateway;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.config.PosProperties;
import java.time.Clock;
import java.util.Arrays;
import java.util.Set;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@EnableScheduling
public class GatewayConfig {

    private static final Set<String> SIMULATOR_PROFILES = Set.of("local", "test");

    @Bean
    PaymentGateway paymentGateway(PosProperties properties, Environment environment, ObjectMapper json) {
        PosProperties.Payment cfg = properties.payment();
        PosProperties.GatewayType type = cfg == null || cfg.gateway() == null
                ? PosProperties.GatewayType.NONE : cfg.gateway();
        return switch (type) {
            case NONE -> new NoGateway();
            case SIMULATOR -> {
                String[] active = environment.getActiveProfiles();
                boolean allowed = active.length > 0 && Arrays.stream(active).allMatch(SIMULATOR_PROFILES::contains);
                if (!allowed) {
                    throw new IllegalStateException(
                            "pos.payment.gateway=SIMULATOR hanya diizinkan dengan profile local/test, aktif: "
                                    + Arrays.toString(active));
                }
                yield new SimulatorGateway(new CallbackSigner(cfg.callbackSecret(), Clock.systemUTC()), json);
            }
        };
    }
}
