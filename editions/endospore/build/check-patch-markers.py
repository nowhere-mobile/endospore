#!/usr/bin/env python3
"""check-patch-markers.py -- hold a built Endospore image to patch-markers.tsv (NWP-20261020-04).

    check-patch-markers.py --table patch-markers.tsv --zip <target_files.zip>
    check-patch-markers.py --table patch-markers.tsv --dir <product out dir>
    check-patch-markers.py --table patch-markers.tsv --self-check <repo>

WHY. A framework patch edits a tree we do not own and is silent when absent: an upstream sync can leave an anchor
that still matches while the patch's own edit lands nowhere, the script exits 0, and every producer logs success.
build-device.sh runs the first two forms after `m`, before signing; CI runs the third. patch-markers.tsv says what
each column and kind means and what makes a marker valid.

ARTIFACTS. Found by BASENAME and required to match exactly once; the path it was found at is printed. In a zip, any
entry whose last path component is the basename (symlink entries are skipped). In a dir, files under system/,
system_ext/, product/ and vendor/ only, symlinks not followed. An .apk or .jar is read as a zip (nested, in memory)
and every classes*.dex in it is searched; any other artifact is searched as raw bytes. Under --zip a missing artifact
FAILS; under --dir it is a WARN naming it (a dev build that built only some partitions). Ambiguous always FAILS.

Exit 0 when nothing FAILED, 1 on any FAIL or table error, 2 on bad usage. Python 3 stdlib only.
"""
import argparse
import glob
import io
import os
import re
import stat
import sys
import zipfile

KINDS = ("need", "control", "absent", "exempt")
DIR_ROOTS = ("system", "system_ext", "product", "vendor")
DEX_RE = re.compile(r"^classes\d*\.dex$")
TOKEN_RE = re.compile(r"nowhere|Nowhere|NWP-\d|DIA-\d")
ARCHIVES = (".apk", ".jar")


class TableError(Exception):
    pass


def parse_table(path):
    """-> [(lineno, patch, artifact, kind, text)]. Raises TableError on a malformed row."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 4:
                raise TableError("%s:%d: %d tab-separated columns, want 4" % (path, n, len(cols)))
            patch, artifact, kind, text = cols
            if kind not in KINDS:
                raise TableError("%s:%d: kind %r is not one of %s" % (path, n, kind, "/".join(KINDS)))
            if not patch or patch != patch.strip() or "/" in patch:
                raise TableError("%s:%d: patch %r must be a bare script name" % (path, n, patch))
            if not text:
                raise TableError("%s:%d: %s row of %s has no text%s" % (
                    path, n, kind, patch, " (an exempt row states its reason)" if kind == "exempt" else
                    " (an empty text matches everything)"))
            if text != text.strip():
                raise TableError("%s:%d: text of %s has leading or trailing space" % (path, n, patch))
            if kind == "exempt" and artifact != "-":
                raise TableError("%s:%d: an exempt row names artifact '-', not %r" % (path, n, artifact))
            if kind != "exempt" and (artifact == "-" or not artifact or "/" in artifact):
                raise TableError("%s:%d: %s row of %s needs an artifact basename" % (path, n, kind, patch))
            rows.append((n, patch, artifact, kind, text))
    return rows


# --- artifact lookup ------------------------------------------------------------------------------------------

def zip_matches(zf, base):
    out = []
    for info in zf.infolist():
        if info.filename.endswith("/") or info.filename.rsplit("/", 1)[-1] != base:
            continue
        if stat.S_ISLNK(info.external_attr >> 16):
            continue
        out.append(info.filename)
    return out


def dir_matches(root, base):
    out = []
    for top in DIR_ROOTS:
        start = os.path.join(root, top)
        if not os.path.isdir(start) or os.path.islink(start):
            continue
        for cur, dirs, files in os.walk(start, followlinks=False):
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(cur, d))]
            for f in files:
                p = os.path.join(cur, f)
                if f == base and not os.path.islink(p):
                    out.append(os.path.relpath(p, root))
    return sorted(out)


def blobs_of(base, data):
    """The byte strings to search: every classes*.dex of an archive, else the file itself."""
    if not base.endswith(ARCHIVES):
        return [data]
    with zipfile.ZipFile(io.BytesIO(data)) as inner:
        return [inner.read(n) for n in inner.namelist() if DEX_RE.match(n.rsplit("/", 1)[-1])]


class Source:
    """A zip or a dir, with each artifact located and read once."""

    def __init__(self, zip_path, dir_path):
        self.zf = zipfile.ZipFile(zip_path) if zip_path else None
        self.root = dir_path
        self.cache = {}

    def locate(self, base):
        if base not in self.cache:
            m = zip_matches(self.zf, base) if self.zf else dir_matches(self.root, base)
            blobs = None
            if len(m) == 1:
                if self.zf:
                    data = self.zf.read(m[0])
                else:
                    with open(os.path.join(self.root, m[0]), "rb") as fh:
                        data = fh.read()
                try:
                    blobs = blobs_of(base, data)
                except zipfile.BadZipFile:
                    blobs = "unreadable as a zip"
            self.cache[base] = (m, blobs)
        return self.cache[base]


def check(rows, src, zip_mode):
    fails = 0
    for _n, patch, base, kind, text in rows:
        if kind == "exempt":
            print("exempt %s -- %s" % (patch, text))
            continue
        found, blobs = src.locate(base)
        head = "%s %s %s" % (patch, base, kind)
        if not found:
            if zip_mode:
                print("FAIL   %s: %s is not in the target-files zip" % (head, base))
                fails += 1
            else:
                print("WARN   %s: %s is not under the product tree (a build of only some partitions?)" % (head, base))
            continue
        if len(found) > 1:
            print("FAIL   %s: ambiguous, %d entries named %s: %s" % (head, len(found), base, ", ".join(found)))
            fails += 1
            continue
        if isinstance(blobs, str):
            print("FAIL   %s: %s is %s (%s)" % (head, base, blobs, found[0]))
            fails += 1
            continue
        present = any(text.encode("utf-8") in b for b in blobs)
        want = kind != "absent"
        if present == want:
            print("ok     %s in %s" % (head, found[0]))
        else:
            print("FAIL   %s in %s: %r is %s" % (head, found[0], text, "missing" if want else "present"))
            fails += 1
    return fails


# --- self-check -----------------------------------------------------------------------------------------------

def applied_set(repo):
    """-> ({patch basename: [script paths]}, [violations]) exactly as build-device.sh applies them."""
    bd = os.path.join(repo, "editions/endospore/build/build-device.sh")
    viol = []
    with open(bd, encoding="utf-8") as fh:
        m = re.search(r'^GOS_MANDATED_PATCHES="([^"]*)"', fh.read(), re.M)
    if not m:
        return {}, ["build-device.sh has no ^GOS_MANDATED_PATCHES=\"...\" line"]
    applied = {}

    def add(name, paths, where):
        if name in applied:
            viol.append("%s is applied twice (%s and %s)" % (name, applied[name][0], where))
            return
        applied[name] = paths

    for n in m.group(1).split():
        p = os.path.join(repo, "editions/diaspore/build/patches", n)
        if not os.path.isfile(p):
            viol.append("mandated patch %s does not exist at %s" % (n, p))
        else:
            add(n, [p], p)
    for p in sorted(glob.glob(os.path.join(repo, "editions/endospore/build/patches/*.sh"))):
        add(os.path.basename(p), [p], p)
    dev = {}
    for p in sorted(glob.glob(os.path.join(repo, "editions/endospore/devices/*/patches/*.sh"))):
        dev.setdefault(os.path.basename(p), []).append(p)
    for n, paths in sorted(dev.items()):
        add(n, paths, paths[0])
    return applied, viol


def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def self_check(repo, table):
    viol = []
    try:
        rows = parse_table(table)
    except TableError as e:
        return [str(e)]
    applied, v = applied_set(repo)
    viol += v
    src = {n: [read(p) for p in paths] for n, paths in applied.items()}
    by_patch = {}
    for r in rows:
        by_patch.setdefault(r[1], []).append(r)
    for n in sorted(applied):
        kinds = {r[3] for r in by_patch.get(n, [])}
        if not kinds & {"need", "exempt"}:
            viol.append("%s is applied by build-device.sh but has no need row and no exempt row" % n)
        if "exempt" in kinds and kinds - {"exempt"}:
            viol.append("%s has an exempt row and a %s row: pick one" % (n, "/".join(sorted(kinds - {"exempt"}))))
    for n in sorted(by_patch):
        if n not in applied:
            viol.append("%s has a row (line %d) but build-device.sh does not apply it" % (n, by_patch[n][0][0]))
    for ln, patch, _base, kind, text in rows:
        if patch not in applied or kind not in ("need", "absent"):
            continue
        for p, body in zip(applied[patch], src[patch]):
            if text not in body:
                viol.append("line %d: %s text %r is not in %s" % (ln, kind, text, os.path.relpath(p, repo)))
        if kind != "need":
            continue
        if not TOKEN_RE.search(text):
            viol.append("line %d: need text %r of %s has no Nowhere-only token (nowhere, Nowhere, NWP-, DIA-)"
                        % (ln, text, patch))
        for other, bodies in src.items():
            if other != patch and any(text in b for b in bodies):
                viol.append("line %d: need text %r of %s also appears in %s" % (ln, text, patch, other))
    return viol


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--table", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--zip")
    g.add_argument("--dir")
    g.add_argument("--self-check", metavar="REPO")
    a = ap.parse_args()
    if a.self_check:
        viol = self_check(a.self_check, a.table)
        for v in viol:
            print("VIOLATION  " + v)
        if viol:
            print("patch-markers self-check: %d violation(s)" % len(viol))
            return 1
        print("patch-markers self-check: ok")
        return 0
    try:
        rows = parse_table(a.table)
        src = Source(a.zip, a.dir)
    except (TableError, OSError, zipfile.BadZipFile) as e:
        print("patch-markers: %s" % e)
        return 1
    fails = check(rows, src, bool(a.zip))
    if fails:
        print("patch-markers: %d FAIL of %d rows" % (fails, len(rows)))
        return 1
    print("patch-markers: ok (%d rows)" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
