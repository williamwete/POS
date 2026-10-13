package com.pirantisolution.pos.platform;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class PlatformDtos {

    private PlatformDtos() {
    }

    public record PlanRow(String code, String name, Integer maxOutlets, Integer maxTerminals, Integer maxUsers,
            Integer maxProducts, BigDecimal priceMonthly) {
    }

    public record MerchantRow(UUID id, String code, String name, String businessType, boolean active, String planCode,
            String subStatus, OffsetDateTime trialEndsAt, long outlets, long terminals, long users, long products,
            OffsetDateTime lastSaleAt, OffsetDateTime createdAt) {
    }

    public record MerchantUserRow(UUID userId, UUID authUserId, String username, String displayName, String email,
            boolean active) {
    }

    public record CreateMerchantRequest(
            @NotBlank @Pattern(regexp = "^[A-Za-z0-9_-]{2,24}$") String code,
            @NotBlank @Size(max = 120) String name,
            @NotBlank @Pattern(regexp = "^(FNB|RETAIL|FASHION|SERVICE|GENERAL)$") String businessType,
            @NotBlank @Pattern(regexp = "^[A-Z0-9_]{2,20}$") String plan,
            @NotBlank @Pattern(regexp = "^[A-Za-z0-9_-]{2,32}$") String outletCode,
            @NotBlank @Size(max = 120) String outletName,
            @NotBlank @Size(max = 120) String ownerName,
            @NotBlank @Email @Size(max = 254) String ownerEmail,
            @NotBlank @Size(max = 72) String ownerPassword) {

        /** Password awal pemilik tidak boleh muncul di log. */
        @Override
        public String toString() {
            return "CreateMerchantRequest[code=" + code + "]";
        }
    }

    public record CreatedMerchant(MerchantRow merchant, String ownerUsername) {
    }

    public record PlanRequest(@NotBlank @Pattern(regexp = "^[A-Z0-9_]{2,20}$") String plan) {
    }

    public record ActiveRequest(boolean active, @Size(max = 200) String reason) {
    }
}
