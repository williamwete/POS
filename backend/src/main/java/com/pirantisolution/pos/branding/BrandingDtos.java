package com.pirantisolution.pos.branding;

import jakarta.validation.constraints.Size;

public final class BrandingDtos {

    private BrandingDtos() {
    }

    /** displayName kosong = pakai nama organisasi; warna/logo kosong = tampilan bawaan. */
    public record BrandingView(String organizationName, String displayName, String primaryColor, String logo) {
    }

    public record SaveBrandingRequest(
            @Size(max = 60) String displayName,
            @Size(max = 7) String primaryColor,
            @Size(max = 100000) String logo) {
    }
}
