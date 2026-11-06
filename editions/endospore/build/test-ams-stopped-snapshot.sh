#!/usr/bin/env bash
# test-ams-stopped-snapshot.sh [--mutate] -- NWP-20261026-26.
#
# WHY THIS IS COMMITTED. patches/endospore-ams-stopped-user-snapshot.sh (NWP-20261005-22) is applied to every Endospore
# build by the glob in build-device.sh and was executed by no suite; patch-markers.tsv holds its register literal, but
# checks a built zip, not the script. The script keeps a stopped user's accounts in RAM so the system's all-users
# enumerations never reopen and rewrite its accounts_de.db. Its python skips on its marker, refuses any anchor whose
# count is not exactly 1 (exit 2) and writes ONCE, at the end. A later edit that relaxes the count check, or writes
# before the last sub, patches a tree whose anchor moved or half-patches it, and a cold-locked user's accounts_de.db is
# rewritten while stopped -- the CE-eviction class of NWP-20261004-01, silent until a device shows it.
#
# The suite builds a SYNTHETIC AccountManagerService.java (no real tree) from every sub() anchor the script carries,
# EXTRACTED from the script (EXTRACTION FAILED, exit 2, when one cannot be), each with context lines either side, and
# pins:
#   (a) pristine -> exit 0; the skip marker once; every replacement once; patch-markers.tsv's literal for this script
#       (read from its row) present in the patched file;
#   (b) a re-run -> exit 0, `already patched`, byte-identical;
#   (c) for EACH anchor: missing -> exit 2 and the file byte-identical; duplicated -> exit 2 and byte-identical;
#   (d) a missing target file -> exit 1.
# It cannot show the anchors still match the real GrapheneOS tree; the build host checks that (docs/framework-patches.md).
#
#   bash test-ams-stopped-snapshot.sh            # the invariants
#   bash test-ams-stopped-snapshot.sh --mutate   # ... plus mutants of the script that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
NAME=endospore-ams-stopped-user-snapshot.sh
SCRIPT0="$HERE/patches/$NAME"
TSV="$HERE/patch-markers.tsv"
AMS_REL=frameworks/base/services/core/java/com/android/server/accounts/AccountManagerService.java
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# pieces: <dir> -- write a<i>.anchor / a<i>.repl for every sub() of the script, the skip marker and the tsv literal.
python3 - "$SCRIPT0" "$TSV" "$NAME" "$W/pieces" <<'PY' || { echo "EXTRACTION FAILED: see above" >&2; exit 2; }
import os, re, sys
script, tsv, name, out = sys.argv[1:5]
src = open(script, encoding="utf-8").read()
subs = re.findall(r"^sub\('''(.*?)''', '''(.*?)''', '([^']*)'\)$", src, re.S | re.M)
calls = len(re.findall(r"^sub\(", src, re.M))
if not subs or len(subs) != calls:
    print("EXTRACTION FAILED: %d of %d sub() calls readable" % (len(subs), calls), file=sys.stderr); sys.exit(2)
m = re.search(r"^MARK = '([^']+)'$", src, re.M)
if not m:
    print("EXTRACTION FAILED: no MARK", file=sys.stderr); sys.exit(2)
rows = [l.split("\t") for l in open(tsv, encoding="utf-8").read().split("\n") if l.startswith(name + "\t")]
if len(rows) != 1 or len(rows[0]) != 4 or not rows[0][3]:
    print("EXTRACTION FAILED: %d usable tsv rows for %s" % (len(rows), name), file=sys.stderr); sys.exit(2)
os.makedirs(out)
for i, (a, r, w) in enumerate(subs):
    if not a.endswith("\n") or not r.endswith("\n"):
        print("EXTRACTION FAILED: sub %d does not end in a newline" % i, file=sys.stderr); sys.exit(2)
    open("%s/a%d.anchor" % (out, i), "w", encoding="utf-8").write(a)
    open("%s/a%d.repl" % (out, i), "w", encoding="utf-8").write(r)
open(out + "/count", "w").write(str(len(subs)))
open(out + "/mark", "w", encoding="utf-8").write(m.group(1))
open(out + "/tsv", "w", encoding="utf-8").write(rows[0][3])
PY
N=$(cat "$W/pieces/count")

# fixture <file> pristine|miss:<i>|dup:<i>
fixture(){
python3 - "$W/pieces" "$N" "$1" "$2" <<'PY'
import sys
d, n, f, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
mode, _, idx = kind.partition(":")
out = ["package com.android.server.accounts;\n", "\n", "public class AccountManagerService {\n"]
for i in range(n):
    a = open("%s/a%d.anchor" % (d, i), encoding="utf-8").read()
    body = a
    if mode == "miss" and int(idx) == i: body = ""
    if mode == "dup" and int(idx) == i: body = a + "    // between\n" + a
    out += ["    // context before %d\n" % i, "    int before%d = %d;\n" % (i, i), body,
            "    int after%d = %d;\n" % (i, i), "    // context after %d\n" % i, "\n"]
out.append("}\n")
import os
os.makedirs(os.path.dirname(f), exist_ok=True)
open(f, "w", encoding="utf-8").write("".join(out))
PY
}

# count_lines <file> <exact line>: how many lines of the file equal it.
count_lines(){ python3 - "$1" "$2" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().split("\n").count(sys.argv[2]))
PY
}
# count_text <file> <piece file> <mark>: occurrences of the piece's text in the file. The script inserts the marker
# line above the snapshot field after its last sub, so a piece holding that field is expected with the line in it.
count_text(){ python3 - "$1" "$2" "$3" <<'PY'
import sys
piece = open(sys.argv[2], encoding="utf-8").read()
field = "    private final SparseArray<Account[]> mNowhereStoppedAccounts"
piece = piece.replace(field, "    // " + sys.argv[3] + "\n" + field, 1)
print(open(sys.argv[1], encoding="utf-8").read().count(piece))
PY
}

FAILED=""
bad(){ FAILED="$FAILED|$1"; echo "FAIL [$1] $2"; }
ok(){ echo "ok   [$1] $2"; }

# checks <script> <label>: every case against one copy of the script; failures land in FAILED as `|<case>`.
checks(){
  local script="$1" t out rc i k before mark tsvlit
  mark=$(cat "$W/pieces/mark"); tsvlit=$(cat "$W/pieces/tsv")
  t=$(mktemp -d -p "$W") || exit 2
  local f="$t/tree/$AMS_REL"

  # (a) pristine
  fixture "$f" pristine
  out=$(bash "$script" "$t/tree" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok a "pristine exits 0" || bad a "pristine exit $rc: $out"
  [ "$(count_lines "$f" "    // $mark")" = 1 ] && ok a "marker once" || bad a "skip marker not written exactly once"
  for ((i = 0; i < N; i++)); do
    [ "$(count_text "$f" "$W/pieces/a$i.repl" "$mark")" = 1 ] || bad a "replacement $i not present exactly once"
  done
  python3 - "$f" "$W/pieces/tsv" <<'PY' && ok a "patch-markers.tsv literal present" || bad a "patch-markers.tsv literal missing from the patched file"
import sys
sys.exit(0 if open(sys.argv[2], encoding="utf-8").read() in open(sys.argv[1], encoding="utf-8").read() else 1)
PY

  # (b) re-run
  cp "$f" "$t/after-a"
  out=$(bash "$script" "$t/tree" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [[ "$out" == *"already patched"* ]] && cmp -s "$f" "$t/after-a"; then ok b "re-run skips, byte-identical"
  else bad b "re-run exit $rc, out: $out"; fi

  # (c) each anchor missing / duplicated
  for ((i = 0; i < N; i++)); do
    for k in miss dup; do
      fixture "$f" "$k:$i"; cp "$f" "$t/before"
      out=$(bash "$script" "$t/tree" 2>&1); rc=$?
      if [ "$rc" = 2 ] && cmp -s "$f" "$t/before"; then ok c "anchor $i $k: exit 2, file untouched"
      else bad "c-$k" "anchor $i $k: exit $rc, file $(cmp -s "$f" "$t/before" && echo untouched || echo CHANGED)"; fi
    done
  done

  # (d) missing file
  rm -rf "$t/none"; out=$(bash "$script" "$t/none" 2>&1); rc=$?
  [ "$rc" = 1 ] && ok d "missing file exits 1" || bad d "missing file exit $rc"
  rm -rf "$t"
}

echo "== ams stopped-user snapshot patch ($N anchors, synthetic tree) =="
checks "$SCRIPT0" real
if [ -n "$FAILED" ]; then echo "RESULT: FAIL ($FAILED)"; exit 1; fi
echo "RESULT: PASS"

[ "$MUTATE" = yes ] || exit 0

# mutants of the script, each must turn the suite red in the named case.
mutant(){   # <id> <case that must fail> <old text> <new text>: exactly one occurrence of old is replaced
  local id="$1" want="$2" old="$3" new="$4" m
  m="$W/mut-$id.sh"
  python3 - "$SCRIPT0" "$m" "$old" "$new" <<'PY' || { echo "MUTANT $id DID NOT APPLY"; return 1; }
import sys
s = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[3], sys.argv[4].replace("\\n", "\n")
if s.count(old) != 1:
    sys.exit(1)
t = s.replace(old, new, 1)
if t == s:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
  cmp -s "$SCRIPT0" "$m" && { echo "MUTANT $id DID NOT CHANGE THE SCRIPT"; return 1; }
  FAILED=""
  checks "$m" "$id" >"$W/mut-$id.out" 2>&1
  if [[ "$FAILED" == *"|$want"* ]]; then echo "CONVICTED $id (case $want)"; return 0; fi
  echo "NOT CONVICTED $id: wanted a failure in case $want, got [$FAILED]"; return 1
}

MFAIL=0
mutant T1 c-dup 'if s.count(anchor) != 1:' 'if s.count(anchor) < 1:' || MFAIL=1
mutant T2 c-miss '    s = s.replace(anchor, repl, 1)' "    s = s.replace(anchor, repl, 1)\\n    open(p, 'w', encoding='utf-8').write(s)" || MFAIL=1
mutant T3 b 'if MARK in s:' "if MARK + ' ' in s:" || MFAIL=1
mutant T4 a 'stopped-user snapshot dropped (NWP-20261005-22)");' 'stopped-user snapshot gone (NWP-20261005-22)");' || MFAIL=1
[ "$MFAIL" = 0 ] || { echo "MUTATE: FAIL"; exit 1; }
echo "MUTATE: PASS (4 mutants convicted)"
