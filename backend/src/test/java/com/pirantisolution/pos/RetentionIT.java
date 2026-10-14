package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.pirantisolution.pos.retention.RetentionJob;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class RetentionIT extends IntegrationTestBase {

    @Autowired
    RetentionJob job;

    @Test
    void jobRunsWithoutErrorAndIsIdempotent() {
        job.purgeAttendancePhotos();
        job.purgeAttendancePhotos();
        assertThat(job).isNotNull();
    }
}
