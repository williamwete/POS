-- V023: branding per merchant (nama tampilan, warna utama, logo). Izin: receipt.manage tingkat organisasi.
-- Logo disimpan sebagai data URL gambar raster kecil (PNG/JPEG/WebP). SVG ditolak karena dapat memuat skrip.
CREATE TABLE pos.organization_branding (
    organization_id  uuid PRIMARY KEY REFERENCES pos.organizations (id),
    display_name     text,
    primary_color    text,
    logo             text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT branding_name_ck CHECK (display_name IS NULL OR pg_catalog.length(btrim(display_name)) BETWEEN 1 AND 60),
    CONSTRAINT branding_color_ck CHECK (primary_color IS NULL OR primary_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT branding_logo_ck CHECK (logo IS NULL OR (pg_catalog.length(logo) <= 100000
        AND logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+=*$'))
);
GRANT SELECT ON pos.organization_branding TO pos_app_user;
ALTER TABLE pos.organization_branding ENABLE ROW LEVEL SECURITY;
CREATE POLICY branding_select ON pos.organization_branding FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());

-- Rasio kontras warna terhadap putih (WCAG). Warna utama dipakai sebagai latar tombol berteks putih.
CREATE OR REPLACE FUNCTION pos.contrast_with_white(p_hex text)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_bytes bytea := decode(substr(p_hex, 2, 6), 'hex');
    v_lum numeric := 0;
    c numeric;
    i integer;
    w numeric[] := ARRAY[0.2126, 0.7152, 0.0722];
BEGIN
    FOR i IN 0..2 LOOP
        c := get_byte(v_bytes, i) / 255.0;
        c := CASE WHEN c <= 0.03928 THEN c / 12.92 ELSE power((c + 0.055) / 1.055, 2.4) END;
        v_lum := v_lum + w[i + 1] * c;
    END LOOP;
    RETURN 1.05 / (v_lum + 0.05);
END
$$;

CREATE OR REPLACE FUNCTION pos.save_branding(p_display_name text, p_color text, p_logo text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_name text := nullif(btrim(coalesce(p_display_name, '')), '');
    v_color text := nullif(btrim(coalesce(p_color, '')), '');
    v_logo text := nullif(btrim(coalesce(p_logo, '')), '');
BEGIN
    PERFORM pos.require_perm('receipt.manage', NULL);
    IF v_color IS NOT NULL THEN
        IF v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
            RAISE EXCEPTION 'CATALOG_INVALID: warna harus berformat #RRGGBB' USING ERRCODE = 'P0001';
        END IF;
        IF pos.contrast_with_white(v_color) < 2.5 THEN
            RAISE EXCEPTION 'CATALOG_INVALID: warna terlalu terang, teks putih pada tombol tidak terbaca' USING ERRCODE = 'P0001';
        END IF;
        v_color := upper(v_color);
    END IF;
    IF v_logo IS NOT NULL AND (pg_catalog.length(v_logo) > 100000
        OR v_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+=*$') THEN
        RAISE EXCEPTION 'CATALOG_INVALID: logo harus PNG/JPEG/WebP kecil (maks ±70 KB)' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.organization_branding (organization_id, display_name, primary_color, logo)
    VALUES (v_org, v_name, v_color, v_logo)
    ON CONFLICT (organization_id) DO UPDATE
        SET display_name = EXCLUDED.display_name, primary_color = EXCLUDED.primary_color,
            logo = EXCLUDED.logo, updated_at = now();
END
$$;
REVOKE ALL ON FUNCTION pos.save_branding(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.save_branding(text, text, text) TO pos_app_user;
