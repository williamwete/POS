#!/usr/bin/env python3
"""
Ekstrak setiap SQL statis dari pemanggilan jdbc.sql(...) di source Java backend, lalu
jalankan PREPARE (parse + analisis tanpa eksekusi) di PostgreSQL yang sudah dimigrasi.

Menangkap: typo nama kolom/tabel, error sintaks, salah tipe, bug konkatenasi string.
Tidak menangkap: kesalahan logika runtime (itu tugas test integrasi).

Pemakaian: python3 backend/scripts/check_sql.py "dbname=pos_rls_test host=localhost user=postgres password=postgres"
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "src" / "main" / "java"


def text_block(src, i):
    """src[i:] dimulai dengan triple quote. Kembalikan (nilai, index setelah penutup)."""
    start = src.index("\n", i) + 1
    end = src.index('"""', start)
    raw = src[start:end]
    lines = raw.split("\n")
    # baris terakhir = indentasi sebelum penutup (bisa berisi konten jika penutup di baris yang sama)
    candidates = [l for l in lines if l.strip()] + [lines[-1]]
    indent = min(len(l) - len(l.lstrip(" ")) for l in candidates)
    out = "\n".join(l[indent:].rstrip(" \t") for l in lines)
    return out.replace("\\n", "\n"), end + 3


def string_literal(src, i):
    j = i + 1
    buf = []
    while src[j] != '"':
        if src[j] == "\\":
            buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(src[j + 1], src[j + 1]))
            j += 2
            continue
        buf.append(src[j])
        j += 1
    return "".join(buf), j + 1


def eval_expr(expr, consts):
    """Evaluasi konkatenasi literal/konstanta. None jika ada bagian dinamis."""
    parts = []
    i = 0
    while i < len(expr):
        c = expr[i]
        if c.isspace() or c == "+":
            i += 1
            continue
        if expr.startswith('"""', i):
            v, i = text_block(expr, i)
            parts.append(v)
        elif c == '"':
            v, i = string_literal(expr, i)
            parts.append(v)
        else:
            m = re.match(r"[A-Z_][A-Z0-9_]*", expr[i:])
            if not m or m.group(0) not in consts:
                return None
            parts.append(consts[m.group(0)])
            i += len(m.group(0))
    return "".join(parts)


def balanced(src, i):
    """src[i] == '('. Kembalikan isi sampai kurung penutup, sadar string/text block."""
    depth = 0
    j = i
    while True:
        if src.startswith('"""', j):
            _, j = text_block(src, j)
            continue
        c = src[j]
        if c == '"':
            _, j = string_literal(src, j)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[i + 1:j], j
        j += 1


def extract(path):
    src = path.read_text()
    consts = {}
    for m in re.finditer(r"static final String ([A-Z_][A-Z0-9_]*)\s*=\s*", src):
        expr_end = src.index(";", m.end()) if not src.startswith('"""', m.end()) else None
        if src.startswith('"""', m.end()):
            v, k = text_block(src, m.end())
            rest_end = src.index(";", k)
            v2 = eval_expr(src[k:rest_end], consts) if src[k:rest_end].strip() else ""
            consts[m.group(1)] = v + (v2 or "")
        else:
            v = eval_expr(src[m.end():expr_end], consts)
            if v is not None:
                consts[m.group(1)] = v
    found = []
    for m in re.finditer(r"jdbc\.sql\(", src):
        inner, _ = balanced(src, m.end() - 1)
        line = src[:m.start()].count("\n") + 1
        found.append((f"{path.relative_to(ROOT)}:{line}", eval_expr(inner, consts)))
    return found


def to_positional(sql):
    names = []

    def repl(m):
        name = m.group(1)
        if name not in names:
            names.append(name)
        return f"${names.index(name) + 1}"

    return re.sub(r"(?<![:\w]):([A-Za-z][A-Za-z0-9]*)", repl, sql)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    conninfo = sys.argv[1]
    statements = []
    skipped = []
    for path in sorted(ROOT.rglob("*.java")):
        for where, sql in extract(path):
            if sql is None:
                skipped.append(where)
            else:
                statements.append((where, to_positional(sql)))

    failures = 0
    for n, (where, sql) in enumerate(statements):
        script = f"SET search_path = pos, public;\nPREPARE chk_{n} AS {sql};\nDEALLOCATE chk_{n};\n"
        r = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", conninfo],
                           input=script, capture_output=True, text=True)
        if r.returncode != 0:
            failures += 1
            print(f"FAIL {where}\n  {r.stderr.strip()}\n  SQL: {' '.join(sql.split())[:300]}")
    print(f"checked {len(statements)} statements, {failures} failed, "
          f"{len(skipped)} dynamic (not checked): {', '.join(skipped)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
