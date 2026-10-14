package com.pirantisolution.pos.retention;

import com.pirantisolution.pos.db.SystemTx;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Retensi data pribadi (UU PDP): menghapus foto absensi yang melewati masa simpan merchant
 * (setting attendance_photo_retention_days, bawaan 90 hari, 0 = simpan selamanya).
 * Idempotent, jadi aman bila lebih dari satu instance menjalankannya bersamaan.
 */
@Component
public class RetentionJob {

    private static final Logger log = LoggerFactory.getLogger(RetentionJob.class);

    private final SystemTx tx;
    private final JdbcClient jdbc;

    public RetentionJob(SystemTx tx, JdbcClient jdbc) {
        this.tx = tx;
        this.jdbc = jdbc;
    }

    @Scheduled(cron = "${pos.retention.cron:0 30 3 * * *}", zone = "Asia/Jakarta")
    public void purgeAttendancePhotos() {
        try {
            int deleted = purgeNow();
            if (deleted > 0) {
                log.info("Retensi: {} foto absensi dihapus", deleted);
            }
        } catch (RuntimeException e) {
            log.warn("Retensi foto absensi gagal: {}", e.getMessage());
        }
    }

    int purgeNow() {
        return tx.system(() -> jdbc.sql("SELECT pos.purge_attendance_photos()").query(Integer.class).single());
    }
}
