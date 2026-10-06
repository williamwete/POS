-- V014: foto produk untuk katalog kasir.
--
-- image_url adalah bagian cache master (ditulis job sync Openbravo / seed, read-only bagi user).
-- Hanya path relatif aplikasi ("/products/...") atau URL https yang diterima, agar katalog tidak
-- bisa diarahkan ke skema berbahaya (javascript:, data:).
ALTER TABLE pos.products
    ADD COLUMN image_url text,
    ADD CONSTRAINT products_image_url_ck CHECK (
        image_url IS NULL
        OR (pg_catalog.length(image_url) <= 500
            AND (image_url ~ '^/[A-Za-z0-9/_.-]+$' OR image_url ~ '^https://[^\s"''<>]+$')));
