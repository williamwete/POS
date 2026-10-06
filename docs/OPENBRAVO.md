# Integrasi Openbravo

POS ↔ Openbravo lewat backend saja (§38). Frontend tidak pernah menyimpan atau menerima kredensial Openbravo.

```
POS frontend → POS backend → antrean sync_jobs → SyncWorker → OpenbravoClient → Openbravo
```

## Konfigurasi (environment server)

| Variabel | Isi |
|---|---|
| `POS_OPENBRAVO_MODE` | `DISABLED` (default produksi: dokumen mengantre, tidak dikirim), `HTTP` (Openbravo sungguhan). `SIMULATOR` hanya untuk profile `local`/`test` — aplikasi menolak start bila dipakai di profile lain. |
| `POS_OPENBRAVO_BASE_URL` | URL Openbravo, wajib `https://` (mis. `https://erp.perusahaan.co.id/openbravo`). |
| `POS_OPENBRAVO_USERNAME` / `POS_OPENBRAVO_PASSWORD` | Akun integrasi khusus dengan hak minimal (baca master, impor dokumen POS). Basic auth. |
| `POS_OPENBRAVO_TIMEOUT_SECONDS` | Default 30. |
| `POS_OPENBRAVO_WORKER_ENABLED` | `true` = antrean diproses otomatis tiap 15 detik. |
| `pos.openbravo.paths.*` | Path endpoint (lihat di bawah) bila berbeda dari default. |

## Pemetaan ID (§39)

Menu **Administrasi → Pemetaan Openbravo** (izin `configuration.manage`): organisasi, outlet, gudang, terminal, metode
pembayaran, pajak. Produk dipetakan otomatis lewat sinkron master (`products.openbravo_product_id`). Dokumen yang memakai
entitas tanpa pemetaan **tidak dikirim** dan langsung masuk *Perlu ditinjau* dengan pesan
`MAPPING_MISSING: <JENIS> <kode>`; setelah pemetaan diisi, tekan **Coba lagi**.

## Dokumen keluar (POS → Openbravo, §41)

Job dibuat oleh database di transaksi yang sama dengan kejadiannya: transaksi **lunas** (SALE), retur **selesai** (RETURN),
**cash-up/Z** dibuat (CASHUP). Retur menunggu penjualan asalnya terkirim; cash-up menunggu semua penjualan & retur
session-nya terkirim.

Backend mengirim `POST {baseUrl}{path}` dengan JSON dan mengharapkan respons `2xx`:

```json
{ "documentId": "<id dokumen di Openbravo>", "documentNo": "<nomor dokumen>" }
```

| Jenis | Path default | Isi utama |
|---|---|---|
| SALE | `/ws/pos-integration/sales` | `externalId` (UUID transaksi POS), `documentNo` (no struk), `organizationId`, `outletId`, `warehouseId`, `terminalId`, `businessDate`, `paidAt`, `cashier`, `pricesIncludeTax`, total; `lines[]` (`productId`, `sku`, `quantity`, `uom`, `listPrice`, `unitPrice`, `discountAmount`, `netAmount`, `taxId`, `taxRate`, `taxAmount`); `payments[]` (`externalId`, `paymentMethodId`, `amount`, `amountReceived`, `changeAmount`, `reference`) |
| RETURN | `/ws/pos-integration/returns` | `externalId`, `documentNo` (RET-…), `originalExternalId`, `originalDocumentId/No`, `lines[]` (`productId`, `quantity`, `amount`, `taxAmount`, `returnToStock`, `originalLineNo`), `refunds[]` (`originalPaymentExternalId`, `paymentMethodId`, `amount`, `reference`) |
| CASHUP | `/ws/pos-integration/cashups` | `externalId`, `terminalId`, `businessDate`, `zNumber`, `expectedCash`, `actualCash`, `difference`, `report` (isi Z report lengkap), `documents[]` |

**Wajib di sisi Openbravo:** endpoint idempotent berdasarkan `externalId` — bila dokumen yang sama dikirim ulang
(retry setelah timeout), kembalikan dokumen yang sudah dibuat, jangan membuat duplikat (§37).

Endpoint impor ini adalah modul/web service di Openbravo (atau middleware) yang membuat Sales Order/Invoice + pembayaran,
Return Material + refund, dan Cash-up sesuai konfigurasi ERP Anda. POS tidak menulis langsung ke tabel Openbravo.

Respons `4xx` (kecuali 408/429) = data ditolak → *Perlu ditinjau*. `5xx`/timeout/koneksi = sementara → dicoba ulang
30 dtk → 1 mnt → 5 mnt → 15 mnt, setelah percobaan ke-5 → *Perlu ditinjau* (§43).

## Master data masuk (Openbravo → POS, §40)

Dibaca dari JSON REST Openbravo (`org.openbravo.service.json.jsonrest`, paging `_startRow/_endRow`) lalu diterjemahkan ke
format ternormalisasi di `HttpOpenbravoClient.normalize` (satu-satunya tempat yang tahu nama field Openbravo):

| Master | Path default | Field Openbravo → POS |
|---|---|---|
| Produk | `/org.openbravo.service.json.jsonrest/Product` | `id`, `searchKey`→sku, `name`, `uOM$_identifier`, `productCategory`, `taxCategory`→taxId, `uPCEAN`→barcode, `active` |
| Harga | `.../PricingProductPrice` | `product`, `listPrice` |
| Stok | `.../MaterialMgmtStorageDetail` | `product`, `warehouse`, `quantityOnHand`, `reservedQty` |
| Customer | `.../BusinessPartner?_where=customer=true` | `id`, `searchKey`, `name`, `taxID`, `active` |

> Nama entitas/field dapat berbeda antar versi & modul Openbravo. **Verifikasi terhadap instance Anda** (mis. dengan
> akun integrasi di `/org.openbravo.service.json.jsonrest/Product?_startRow=0&_endRow=1`), lalu sesuaikan path
> (`pos.openbravo.paths.*`) atau fungsi `normalize`. Untuk stok, gunakan datasource/view yang menyertakan gudang.

Format ternormalisasi yang diterima database (`pos.sync_upsert_*`): produk
`{id, sku, name, uom, categoryId, categoryCode, categoryName, taxId, barcodes[], active}`, harga `{productId, price,
outletId?}`, stok `{productId, warehouseId, quantity, available}`, customer `{id, code, name, phone, email, taxId, active}`.
Baris yang gagal dicatat (`records_failed`, contoh error) tanpa membatalkan baris lain. Harga yang berubah menjadi versi
harga baru (riwayat tidak ditimpa); stok selalu snapshot Openbravo (POS tidak menghitung stok sendiri).

Sinkron master dijalankan dari menu **Sinkronisasi** (izin `sync.manage`) atau `POST /api/sync/run {"types": [...]}`.

## Simulator (local)

Profile `local` memakai simulator: master data demo (sama dengan seed), nomor dokumen `SIM/SO/…`, `SIM/RM/…`,
`SIM/CU/…`. Pemetaan demo memakai ID `DEMO-…`. Ganti `POS_OPENBRAVO_MODE=HTTP` + kredensial untuk mencoba server
Openbravo sungguhan dari lokal.
