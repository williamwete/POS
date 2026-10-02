-- Bootstrap organisasi + SUPER_ADMIN pertama di staging/production (dijalankan SEKALI oleh
-- operator sebagai owner database, setelah akun dibuat di Supabase Auth).
--
--   psql "$MIGRATION_DATABASE_URL" \
--     -v org_code=ACME -v org_name='PT Acme Retail' \
--     -v auth_user_id=<uuid dari Supabase Auth> -v username=sari.admin \
--     -v email=sari@acme.co.id -v display_name='Sari Admin' \
--     -f db/bootstrap/bootstrap_super_admin.sql
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO pos.organizations (code, name)
VALUES (:'org_code', :'org_name')
ON CONFLICT (code) DO NOTHING;

INSERT INTO pos.users (auth_user_id, organization_id, username, email, display_name)
SELECT :'auth_user_id'::uuid, o.id, :'username', lower(:'email'), :'display_name'
FROM pos.organizations o WHERE o.code = :'org_code';

INSERT INTO pos.user_roles (user_id, role_id, outlet_id)
SELECT u.id, r.id, NULL
FROM pos.users u, pos.roles r
WHERE u.auth_user_id = :'auth_user_id'::uuid AND r.code = 'SUPER_ADMIN';

INSERT INTO pos.audit_logs (organization_id, actor_type, action, entity_type, entity_id, reason)
SELECT u.organization_id, 'SYSTEM', 'USER_CREATED', 'USER', u.id::text, 'Bootstrap SUPER_ADMIN pertama'
FROM pos.users u WHERE u.auth_user_id = :'auth_user_id'::uuid;

COMMIT;
