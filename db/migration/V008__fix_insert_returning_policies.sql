-- V008: perbaikan policy SELECT untuk INSERT ... RETURNING
--
-- Bug (ditemukan CI 2026-10-02): policy SELECT pada pos.users dan pos.outlets memanggil fungsi
-- STABLE yang membaca ulang tabel yang sama (user_org_id / accessible_outlet_ids). Saat
-- INSERT ... RETURNING, baris baru belum terlihat oleh snapshot fungsi tersebut sehingga
-- pemeriksaan RLS gagal dan admin tidak dapat membuat user atau outlet.
--
-- Perbaikan: policy memakai kolom baris itu sendiri (organization_id) dan tidak pernah
-- mencari ulang baris yang sedang diperiksa.

-- Akses outlet dari data baris (tanpa membaca pos.outlets).
CREATE OR REPLACE FUNCTION pos.can_access_outlet_row(p_outlet_id uuid, p_organization_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT p_outlet_id IS NOT NULL
       AND p_organization_id = pos.current_org_id()
       AND (
            pos.has_org_wide_role()
         OR EXISTS (SELECT 1 FROM pos.user_outlets uo
                    WHERE uo.user_id = pos.current_app_user_id() AND uo.outlet_id = p_outlet_id)
       )
$$;

-- Melihat user dari data baris (tanpa membaca pos.users untuk baris yang sama).
CREATE OR REPLACE FUNCTION pos.can_view_user_row(p_user_id uuid, p_organization_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT p_user_id = pos.current_app_user_id()
        OR (p_organization_id = pos.current_org_id()
            AND (pos.has_permission('user.view', NULL)
                 OR pos.has_permission('user.manage', NULL)
                 OR EXISTS (SELECT 1 FROM pos.user_outlets uo
                            WHERE uo.user_id = p_user_id
                              AND pos.has_permission('user.view', uo.outlet_id))))
$$;

REVOKE ALL ON FUNCTION pos.can_access_outlet_row(uuid, uuid), pos.can_view_user_row(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.can_access_outlet_row(uuid, uuid), pos.can_view_user_row(uuid, uuid)
    TO pos_app_user, pos_system;

DROP POLICY outlets_select ON pos.outlets;
CREATE POLICY outlets_select ON pos.outlets FOR SELECT TO pos_app_user
    USING (pos.can_access_outlet_row(id, organization_id));

DROP POLICY outlets_update ON pos.outlets;
CREATE POLICY outlets_update ON pos.outlets FOR UPDATE TO pos_app_user
    USING (pos.can_access_outlet_row(id, organization_id) AND pos.has_permission('outlet.manage', NULL))
    WITH CHECK (organization_id = pos.current_org_id());

DROP POLICY users_select ON pos.users;
CREATE POLICY users_select ON pos.users FOR SELECT TO pos_app_user
    USING (pos.can_view_user_row(id, organization_id));
