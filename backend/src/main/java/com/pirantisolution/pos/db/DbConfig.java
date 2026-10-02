package com.pirantisolution.pos.db;

import com.fasterxml.jackson.databind.ObjectMapper;
import javax.sql.DataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.annotation.EnableTransactionManagement;

@Configuration
@EnableTransactionManagement
public class DbConfig {

    /** Menggantikan transaction manager default Spring Boot. */
    @Bean
    public RlsTransactionManager transactionManager(DataSource dataSource, ObjectMapper objectMapper) {
        return new RlsTransactionManager(dataSource, objectMapper);
    }
}
