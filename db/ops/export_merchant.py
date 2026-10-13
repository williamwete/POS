#!/usr/bin/env python3
"""Ekspor seluruh data satu merchant (backup per merchant / permintaan subjek data UU PDP).

Pemakaian (sebagai owner database, bukan pos_api):
  python3 -I db/ops/export_merchant.py "<conn-string>" <KODE_MERCHANT> <folder_keluar>

Hasil: satu CSV per tabel + MANIFEST.csv (jumlah baris). Tabel anak tanpa organization_id
ditemukan lewat rantai foreign key. Kolom rahasia (hash PIN) dikosongkan.
Tabel global (plans, permissions, setting_definitions, roles) tidak diekspor.
"""
import csv, os, subprocess, sys

REDACT = {("employee_pins", "pin_hash"), ("employee_pins", "salt")}
SKIP = {"plans", "permissions", "setting_definitions", "roles", "role_permissions",
        "menu_defaults", "menu_items", "idempotency_keys", "terminal_receipt_sequences", "terminal_return_sequences"}

def psql(conn, sql):
    r = subprocess.run(["psql", conn, "-X", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    return [l.split("\t") for l in r.stdout.splitlines() if l]

def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    conn, code, out = sys.argv[1:]
    code_ok = "".join(ch for ch in code if ch.isalnum() or ch in "_-")
    if code_ok != code:
        sys.exit("kode merchant tidak valid")
    org = psql(conn, f"select id from pos.organizations where code='{code}'")
    if not org:
        sys.exit("merchant tidak ditemukan")
    org = org[0][0]
    tables = [r[0] for r in psql(conn, "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='pos' and relkind='r' order by 1")]
    direct = {r[0] for r in psql(conn, "select c.relname from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='pos' and c.relkind='r' and a.attname='organization_id' and not a.attisdropped")}
    fks = {}  # tabel -> [(kolom_anak, tabel_induk, kolom_induk)]
    for t, ccol, pt, pcol in psql(conn, """select c.relname, a.attname, p.relname, pa.attname
        from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_class p on p.oid=k.confrelid
        join pg_namespace n on n.oid=c.relnamespace
        join pg_attribute a on a.attrelid=c.oid and a.attnum=k.conkey[1]
        join pg_attribute pa on pa.attrelid=p.oid and pa.attnum=k.confkey[1]
        where k.contype='f' and n.nspname='pos' and array_length(k.conkey,1)=1"""):
        fks.setdefault(t, []).append((ccol, pt, pcol))
    where = {"organizations": f"id='{org}'"}
    for t in direct:
        where[t] = f"organization_id='{org}'"
    for _ in range(6):  # rantai FK sampai stabil
        for t in tables:
            if t in where or t in SKIP:
                continue
            for ccol, pt, pcol in fks.get(t, []):
                if pt in where and pt != "organizations":
                    where[t] = f'"{ccol}" in (select "{pcol}" from pos.{pt} where {where[pt]})'
                    break
    os.makedirs(out, exist_ok=True)
    manifest = []
    for t in sorted(where):
        cols = [r[0] for r in psql(conn, f"select column_name from information_schema.columns where table_schema='pos' and table_name='{t}' order by ordinal_position")]
        sel = ", ".join("NULL AS " + c if (t, c) in REDACT else f'"{c}"' for c in cols)
        sql = f"copy (select {sel} from pos.{t} where {where[t]}) to stdout with csv header"
        with open(os.path.join(out, t + ".csv"), "w") as f:
            r = subprocess.run(["psql", conn, "-X", "-v", "ON_ERROR_STOP=1", "-c", sql], stdout=f, stderr=subprocess.PIPE, text=True)
        if r.returncode:
            sys.exit(f"{t}: {r.stderr}")
        n = sum(1 for _ in open(os.path.join(out, t + ".csv"))) - 1
        manifest.append((t, n))
    with open(os.path.join(out, "MANIFEST.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["table", "rows"]); w.writerows(manifest)
    missing = [t for t in tables if t not in where and t not in SKIP]
    print(f"{len(manifest)} tabel diekspor ke {out}; tidak terjangkau: {missing or '-'}")

main()
