#!/usr/bin/env bash
# test-patch-markers.sh [--mutate] -- check-patch-markers.py, patch-markers.tsv and the call in build-device.sh
# (NWP-20261020-04).
#
# WHY. A framework patch edits a tree we do not own and is silent when absent; the build's patch loop only proves each
# script exited 0. build-device.sh now holds the BUILT artifact to patch-markers.tsv before signing, and CI holds the
# table to the scripts. This suite pins, on synthetic fixtures (python3 zipfile: deflated entries, jars and apks nested
# in a target-files zip, a raw binary, a product-out tree, and a fixture repo):
#   (a) every need/control present and every absent absent -> exit 0, one ok per row;
#   (b) a need that lives only in classes2.dex is found; a literal only in a non-dex jar member is not; one need
#       missing -> exit 1 naming its patch;
#   (c) an absent text that is present -> exit 1;   (d) a missing control -> exit 1;
#   (e) --zip with the artifact missing -> exit 1; --dir with it missing -> WARN, exit 0 (also a copy outside
#       system/ system_ext/ product/ vendor/ is not found);
#   (f) two entries with one basename -> exit 1 'ambiguous' (zip and dir);
#   (g) --self-check passes on the real repo, and on a fixture repo each of these fails it: a row whose text is not in
#       its resolved script (incl. a text only in the OTHER edition's same-basename script), a device row missing from
#       one device's copy, a need text that also appears in a second applied script, an applied patch with no row, an
#       exempt row with no reason, a row for a patch that is not applied, a need text with no Nowhere-only token;
#   (h) build-device.sh calls the checker between the build-number assert and `if [ "$DO_RELEASE" -eq 0 ]`, outside
#       the PREP block (pinned by anchor), picks --zip for SRC=tfi and --dir for SRC=prodout, and fails the build when
#       the checker does (the lifted block is run against a stub checker).
# Env: CHK / BD override the checker and build-device.sh under test (to run this against origin/main's tree, where
# neither exists, and see it fail).
#   bash test-patch-markers.sh            # the cases
#   bash test-patch-markers.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHK0="${CHK:-$HERE/check-patch-markers.py}"
BD0="${BD:-$HERE/build-device.sh}"
TABLE="$HERE/patch-markers.tsv"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

NEED_A='nowhere: needle-alpha (NWP-20261020-91)'
NEED_B='nowhere: needle-bravo-only-in-classes2'
CTRL='Duplicate startWrite call?'
SUI_NEED='Nowhere: NOT restarting sleep state (NWP-20260825-03)'
SUI_ORIG='Restarting sleep state'
KSN='KeystoreDB::nowhere_dump_user_keys'
DECOY='nowhere: decoy-in-a-non-dex-member'

# --- fixtures ----------------------------------------------------------------------------------------------------
python3 - "$W" "$NEED_A" "$NEED_B" "$CTRL" "$SUI_NEED" "$KSN" "$DECOY" <<'PY'
import io, os, sys, zipfile
w, need_a, need_b, ctrl, sui, ks, decoy = sys.argv[1:8]
D = zipfile.ZIP_DEFLATED
def jar(members):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", D) as z:
        for n, d in members.items():
            z.writestr(n, d)
    return b.getvalue()
dex = lambda *s: b"dex\n035\0" + b"\0".join(x.encode() for x in s)
services = jar({"classes.dex": dex(ctrl, need_a), "classes2.dex": dex(need_b), "assets/x.txt": decoy.encode()})
sysui = jar({"classes.dex": dex(sui, "Other text")})
files = {"SYSTEM/framework/services.jar": services, "SYSTEM_EXT/priv-app/SystemUI/SystemUI.apk": sysui,
         "SYSTEM/bin/keystore2": b"\x7fELF\0" + ks.encode() + b"\0tail"}
def mkzip(path, extra=None):
    with zipfile.ZipFile(path, "w", D) as z:
        for n, d in {**files, **(extra or {})}.items():
            z.writestr(n, d)
mkzip(w + "/ok.zip")
mkzip(w + "/dup.zip", {"SYSTEM/other/services.jar": services})
mkzip(w + "/stray.zip", {"META/Stray.apk": sysui})
for name, extra in (("dir", {}), ("dupdir", {"system/other/services.jar": services}),
                    ("outside", {"obj/Outside.apk": sysui})):
    for n, d in {**{k.split("/", 1)[0].lower() + "/" + k.split("/", 1)[1]: v for k, v in files.items()}, **extra}.items():
        p = os.path.join(w, name, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(d)
os.symlink("/nonexistent/Linked.apk", w + "/dir/system/Linked.apk")
PY
mk_table(){ # <file> <p|a|k|t>...
  local f="$1" r; shift; : > "$f"
  for r in "$@"; do IFS='|' read -r p a k t <<<"$r"; printf '%s\t%s\t%s\t%s\n' "$p" "$a" "$k" "$t" >> "$f"; done
}
FULL=("p1.sh|services.jar|need|$NEED_A" "p1.sh|services.jar|need|$NEED_B" "p1.sh|services.jar|control|$CTRL"
      "p2.sh|SystemUI.apk|need|$SUI_NEED" "p2.sh|SystemUI.apk|absent|$SUI_ORIG" "p3.sh|keystore2|need|$KSN"
      "p4.sh|-|exempt|behavioural tell only")
mk_table "$W/full.tsv" "${FULL[@]}"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
OUT=""; RC=0
run(){ OUT=$(python3 "$CHK" "$@" 2>&1); RC=$?; }
rc_is(){ [ "$RC" = "$2" ] && ok "$1" || no "$1 -- exit $RC, want $2: $(printf %s "$OUT" | tail -3 | tr '\n' '/')"; }
says(){ [[ "$OUT" == *"$2"* ]] && ok "$1" || no "$1 -- output lacks [$2]: $(printf %s "$OUT" | tail -3 | tr '\n' '/')"; }
count(){ local n; n=$(printf '%s\n' "$OUT" | grep -c "^$2"); [ "$n" = "$3" ] && ok "$1" || no "$1 -- $n lines start $2, want $3"; }

# --- fixture repo for the self-check -----------------------------------------------------------------------------
mkrepo(){ # <dir>: a valid layout; the cases then break one thing each
  local r="$1" p
  mkdir -p "$r/editions/endospore/build/patches" "$r/editions/diaspore/build/patches" \
           "$r/editions/endospore/devices/d1/patches" "$r/editions/endospore/devices/d2/patches"
  printf '#!/bin/bash\nGOS_MANDATED_PATCHES="m1.sh m2.sh"\n' > "$r/editions/endospore/build/build-device.sh"
  echo 'echo NWP-1-m1marker' > "$r/editions/diaspore/build/patches/m1.sh"
  echo 'echo nowhere m2marker' > "$r/editions/diaspore/build/patches/m2.sh"
  echo 'echo nowhere t-dia-marker' > "$r/editions/diaspore/build/patches/t.sh"      # same basename, NOT applied
  echo 'echo nowhere e1marker' > "$r/editions/endospore/build/patches/e1.sh"
  echo 'echo nowhere t-end-marker' > "$r/editions/endospore/build/patches/t.sh"
  echo 'echo no literal' > "$r/editions/endospore/build/patches/e2.sh"
  for p in d1 d2; do echo 'echo NWP-9 dv-marker' > "$r/editions/endospore/devices/$p/patches/dv.sh"; done
  mk_table "$r/t.tsv" "m1.sh|a.jar|need|NWP-1-m1marker" "m2.sh|a.jar|need|nowhere m2marker" \
    "e1.sh|a.jar|need|nowhere e1marker" "t.sh|a.jar|need|nowhere t-end-marker" "dv.sh|b.apk|need|NWP-9 dv-marker" \
    "e2.sh|-|exempt|no literal to find"
}
selfcheck(){ run --table "$1/t.tsv" --self-check "$1"; }

cases(){
  CHK="$1"; BD="$2"
  echo "== (a)-(f) artifact checks"
  run --table "$W/full.tsv" --zip "$W/ok.zip"
  rc_is "(a) all present, absent absent -> exit 0" 0
  count "(a) one ok per non-exempt row" ok 6
  count "(a) one exempt line" exempt 1
  says "(a) the path it was found at is printed" "SYSTEM/framework/services.jar"
  mk_table "$W/b1.tsv" "p1.sh|services.jar|need|$NEED_B"
  run --table "$W/b1.tsv" --zip "$W/ok.zip"; rc_is "(b) a need only in classes2.dex is found" 0
  mk_table "$W/b2.tsv" "p1.sh|services.jar|need|$DECOY"
  run --table "$W/b2.tsv" --zip "$W/ok.zip"; rc_is "(b) a literal in a non-dex jar member is not found" 1
  mk_table "$W/b3.tsv" "${FULL[@]:0:5}" "p3.sh|keystore2|need|$KSN-gone"
  run --table "$W/b3.tsv" --zip "$W/ok.zip"
  rc_is "(b) one need missing -> exit 1" 1
  says "(b) ... naming the patch" "p3.sh keystore2 need"
  mk_table "$W/c.tsv" "p2.sh|SystemUI.apk|absent|$SUI_NEED"
  run --table "$W/c.tsv" --zip "$W/ok.zip"; rc_is "(c) an absent text that is present -> exit 1" 1
  mk_table "$W/d.tsv" "p1.sh|services.jar|control|No such stock string"
  run --table "$W/d.tsv" --zip "$W/ok.zip"; rc_is "(d) a missing control -> exit 1" 1
  mk_table "$W/e.tsv" "p9.sh|Missing.apk|need|$NEED_A"
  run --table "$W/e.tsv" --zip "$W/ok.zip"; rc_is "(e) --zip, artifact missing -> exit 1" 1
  run --table "$W/e.tsv" --dir "$W/dir"; rc_is "(e) --dir, artifact missing -> exit 0" 0
  says "(e) ... as a WARN naming it" "WARN   p9.sh Missing.apk"
  run --table "$W/full.tsv" --dir "$W/dir"; rc_is "(e) --dir, full tree -> exit 0" 0
  count "(e) --dir, one ok per row" ok 6
  mk_table "$W/o.tsv" "p9.sh|Outside.apk|need|Other text"
  run --table "$W/o.tsv" --dir "$W/outside"; says "(e) --dir does not look outside the partition roots" "WARN"
  mk_table "$W/l.tsv" "p9.sh|Linked.apk|need|x"
  run --table "$W/l.tsv" --dir "$W/dir"; says "(e) --dir does not follow symlinks" "WARN"
  run --table "$W/full.tsv" --zip "$W/dup.zip"
  rc_is "(f) two zip entries with one basename -> exit 1" 1
  says "(f) ... ambiguous" "ambiguous"
  run --table "$W/full.tsv" --dir "$W/dupdir"
  rc_is "(f) two files with one basename under --dir -> exit 1" 1
  says "(f) ... ambiguous (dir)" "ambiguous"
  printf 'p1.sh\tservices.jar\tneed\n' > "$W/bad.tsv"
  run --table "$W/bad.tsv" --zip "$W/ok.zip"; rc_is "a row with three columns is a table error" 1

  echo "== (g) self-check"
  run --table "$TABLE" --self-check "$REPO"; rc_is "(g) the real table passes on the real repo" 0
  local r="$W/repo"; rm -rf "$r"; mkrepo "$r"
  selfcheck "$r"; rc_is "(g) the fixture repo is valid" 0
  sed -i 's/^t\.sh\t\(.*\)\tnowhere t-end-marker$/t.sh\t\1\tnowhere t-dia-marker/' "$r/t.tsv"
  selfcheck "$r"; rc_is "(g) a text only in the OTHER edition's same-basename script -> exit 1" 1
  says "(g) ... naming the row" "t-dia-marker"
  rm -rf "$r"; mkrepo "$r"; echo 'echo none' > "$r/editions/endospore/devices/d2/patches/dv.sh"
  selfcheck "$r"; rc_is "(g) a device row missing from one device's copy -> exit 1" 1
  says "(g) ... naming that copy" "devices/d2/patches/dv.sh"
  rm -rf "$r"; mkrepo "$r"; echo 'echo nowhere e1marker' >> "$r/editions/diaspore/build/patches/m2.sh"
  selfcheck "$r"; rc_is "(g) a need text also in a second applied script -> exit 1" 1
  says "(g) ... naming it" "also appears in m2.sh"
  rm -rf "$r"; mkrepo "$r"; echo 'echo nowhere dv' >> "$r/editions/endospore/build/patches/e1.sh"
  echo 'echo NWP-9 dv-marker' >> "$r/editions/endospore/build/patches/e1.sh"
  selfcheck "$r"; rc_is "(g) a device patch's text in an applied edition script -> exit 1" 1
  rm -rf "$r"; mkrepo "$r"; sed -i '/^e1\.sh/d' "$r/t.tsv"
  selfcheck "$r"; rc_is "(g) an applied patch with no row -> exit 1" 1
  says "(g) ... naming it" "e1.sh is applied"
  rm -rf "$r"; mkrepo "$r"; sed -i '/^e2\.sh/d' "$r/t.tsv"; printf 'e2.sh\t-\texempt\t\n' >> "$r/t.tsv"
  selfcheck "$r"; rc_is "(g) an exempt row with no reason -> exit 1" 1
  rm -rf "$r"; mkrepo "$r"; printf 'ghost.sh\ta.jar\tneed\tnowhere ghost\n' >> "$r/t.tsv"
  selfcheck "$r"; rc_is "(g) a row for a patch build-device.sh does not apply -> exit 1" 1
  rm -rf "$r"; mkrepo "$r"; echo 'echo generic words' >> "$r/editions/endospore/build/patches/e2.sh"
  printf 'e2.sh\ta.jar\tneed\tgeneric words\n' >> "$r/t.tsv"; sed -i '/^e2\.sh\t-/d' "$r/t.tsv"
  selfcheck "$r"; rc_is "(g) a need text with no Nowhere-only token -> exit 1" 1
  rm -rf "$r"; mkrepo "$r"; sed -i 's/m2.sh"/m2.sh gone.sh"/' "$r/editions/endospore/build/build-device.sh"
  selfcheck "$r"; rc_is "(g) a mandated name that does not exist -> exit 1" 1

  echo "== (h) build-device.sh"
  hcheck "$BD"
}

# hcheck <build-device.sh>: the call's place, by anchor, and its behaviour, by running the lifted block.
hcheck(){
  local f="$1" verdict
  verdict=$(python3 - "$f" <<'PY'
import re, sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
def first(pat, start=0):
    for i in range(start, len(L)):
        if re.search(pat, L[i]): return i
    return -1
bn = first(r'^\[ "\$IMG_BN" = "\$BN" \] \|\| fail ')
rel = first(r'^if \[ "\$DO_RELEASE" -eq 0 \]; then', bn + 1) if bn >= 0 else -1
calls = [i for i, l in enumerate(L) if "check-patch-markers.py" in l and l.lstrip().startswith("python3")]
if bn < 0 or rel < 0: print("no anchors"); sys.exit()
if not calls: print("no call"); sys.exit()
if not all(bn < i < rel for i in calls): print("call outside the build-number assert .. DO_RELEASE span"); sys.exit()
prep = max((i for i, l in enumerate(L) if re.match(r'if \[ "\$PREP" = 1 \]; then', l) and i < calls[0]), default=-1)
close = first(r'^fi$', prep + 1) if prep >= 0 else -1
if prep >= 0 and close > calls[0]: print("call inside the PREP block"); sys.exit()
tail = '|| fail "a framework patch\'s artifact literal is missing -- do not sign this"'
if len(calls) != 2: print("want one --zip and one --dir call"); sys.exit()
for i, flag in zip(calls, ('--zip "$TFI"', '--dir "$PRODOUT"')):
    if flag not in L[i]: print("call lacks " + flag); sys.exit()
    if tail not in (L[i] + " " + L[i + 1]): print("call is not followed by || fail"); sys.exit()
print("ok")
PY
  )
  [ "$verdict" = ok ] && ok "(h) the call sits between the build-number assert and DO_RELEASE, outside PREP, --zip/--dir, || fail" \
    || no "(h) placement: $verdict"
  # behaviour: lift the block between the two anchors, run it against a stub checker
  local blk="$W/blk.sh" stub="$W/stubrepo" n
  mkdir -p "$stub/editions/endospore/build"
  sed -n '/^\[ "\$IMG_BN" = "\$BN" \] || fail /,/^if \[ "\$DO_RELEASE" -eq 0 \]/ p' "$f" | sed '1d;$d' > "$blk"
  printf '%s\n' '#!/usr/bin/env python3' 'import os, sys' \
    'open(os.environ["STUBLOG"], "a").write(" ".join(sys.argv[1:]) + "\n")' 'sys.exit(int(os.environ["STUBRC"]))' \
    > "$stub/editions/endospore/build/check-patch-markers.py"
  for n in tfi prodout; do
    local want; [ "$n" = tfi ] && want='--zip /t/z.zip' || want='--dir /t/prod'
    : > "$W/stub.log"
    local o rc
    o=$(STUBLOG="$W/stub.log" STUBRC=0 REPO="$stub" SRC=$n TFI=/t/z.zip PRODOUT=/t/prod bash -c \
        'fail(){ echo "FAILED: $1"; exit 1; }; . "$0"; echo REACHED' "$blk" 2>&1); rc=$?
    [ "$rc" = 0 ] && [[ "$o" == *REACHED* ]] && [[ "$(cat "$W/stub.log")" == *"$want" ]] \
      && ok "(h) SRC=$n, checker passes -> runs it with $want and carries on" \
      || no "(h) SRC=$n, checker passes: rc=$rc log=[$(cat "$W/stub.log")] out=[$o]"
    o=$(STUBLOG="$W/stub.log" STUBRC=1 REPO="$stub" SRC=$n TFI=/t/z.zip PRODOUT=/t/prod bash -c \
        'fail(){ echo "FAILED: $1"; exit 1; }; . "$0"; echo REACHED' "$blk" 2>&1); rc=$?
    [ "$rc" = 1 ] && [[ "$o" == *"FAILED: a framework patch's artifact literal is missing -- do not sign this"* ]] \
      && [[ "$o" != *REACHED* ]] && ok "(h) SRC=$n, checker fails -> the build fails before signing" \
      || no "(h) SRC=$n, checker fails: rc=$rc out=[$o]"
  done
}

cases "$CHK0" "$BD0"

if [ "$MUTATE" = yes ]; then
  echo "== mutants"
  mutant(){ # <name> <file: chk|bd> <old> <new> [<old> <new>]...
    local name="$1" kind="$2"; shift 2
    local M="$W/mut-$name"; mkdir -p "$M"
    local src; [ "$kind" = chk ] && src="$CHK0" || src="$BD0"
    python3 - "$src" "$M/out" "$@" <<'PY' || { no "mutant $name did not apply"; return; }
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = sys.argv[3:]
for old, new in zip(a[::2], a[1::2]):
    if s.count(old) != 1:
        sys.exit("anchor %r found %d times" % (old, s.count(old)))
    s = s.replace(old, new)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
    local out
    if [ "$kind" = chk ]; then out=$(cases "$M/out" "$BD0"); else out=$(cases "$CHK0" "$M/out"); fi
    # a mutant is convicted only by a printed FAIL line (cases ran in a subshell; its own counters are not ours)
    if [[ "$out" == *"  FAIL  "* ]]; then ok "mutant $name convicted"; else no "mutant $name SURVIVED"; fi
  }
  mutant classes2-not-searched chk \
    'if DEX_RE.match(n.rsplit("/", 1)[-1])]' 'if n == "classes.dex"]'
  mutant absent-as-need chk 'want = kind != "absent"' 'want = True'
  mutant missing-passes-under-zip chk 'if zip_mode:' 'if False:'
  mutant ambiguity-removed chk 'if len(found) > 1:' 'if False:'
  mutant coverage-loop-removed chk 'if not kinds & {"need", "exempt"}:' 'if False:'
  mutant uniqueness-removed chk 'if other != patch and any(text in b for b in bodies):' 'if False:'
  mutant search-all-dirs chk \
    'if text not in body:' 'if not any(text in b for b in src[patch]):' \
    'applied[name] = paths' 'applied[name] = paths + [q for q in glob.glob(os.path.join(repo, "editions/*/build/patches/*.sh")) if os.path.basename(q) == name and q not in paths]'
  mutant bd-call-removed bd \
    "$(printf 'if [ "$SRC" = tfi ]; then\n  python3 "$REPO/editions/endospore/build/check-patch-markers.py"')" \
    "$(printf 'if false; then\n  true "$REPO/editions/endospore/build/check-patch-markers.py"')" \
    "$(printf 'else\n  python3 "$REPO/editions/endospore/build/check-patch-markers.py"')" \
    "$(printf 'else\n  true "$REPO/editions/endospore/build/check-patch-markers.py"')"
  mutant bd-fail-dropped-zip bd \
    '--zip "$TFI" \
    || fail "a framework patch'"'"'s artifact literal is missing -- do not sign this"' '--zip "$TFI" || true'
  mutant bd-fail-dropped-dir bd \
    '--dir "$PRODOUT" \
    || fail "a framework patch'"'"'s artifact literal is missing -- do not sign this"' '--dir "$PRODOUT" || true'
fi
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
