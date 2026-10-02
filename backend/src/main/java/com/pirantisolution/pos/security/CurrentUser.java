package com.pirantisolution.pos.security;

import java.util.UUID;

/** Identitas user yang sedang request, sudah diverifikasi aktif oleh database. */
public record CurrentUser(UUID userId, UUID organizationId, UUID employeeId, String username) {
}
