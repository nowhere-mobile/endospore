#!/usr/bin/env bash
# test-ring-patch-guard.sh [--mutate] [<ring script>...] -- NWP-20261027-13.
#
# WHY THIS IS COMMITTED. launcher3-media-progress-ring.sh is applied to every Endospore build by build-device.sh's
# device-patch glob, and no suite executed it (test-ring-smooth.sh runs only the smoothing patch, on trees that
# already carry the ring). Its re-run guard read ONE marker, in the first of three patched files, so a run that
# stopped after BubbleTextView.java was "already applied" at the next build on the shared tree: the image shipped
# with a ring missing from the workspace/hotseat icons, silently.
#
# These cases run each of the five device copies on SYNTHETIC trees built from the script's own hunks (the ' ' and
# '-' lines of each hunk plus filler, read out of the script under test, so an edit to a hunk changes the fixture
# with it): apply, re-run, drift, half-applied, missing file. They cannot show that the hunks still apply to the
# real GrapheneOS tree -- that is the next Endospore build's. Bash only: the script is run as `bash "$p"` by
# build-device.sh and never on the device, so the dash/mksh loop does not apply. Needs patch and python3.
#
#   bash test-ring-patch-guard.sh              # the five copies under editions/endospore/devices/*/patches, and the
#                                              # Diaspore Trebuchet twin
#   bash test-ring-patch-guard.sh --mutate     # ... plus mutants that must each CONVICT the suite
#   bash test-ring-patch-guard.sh <script>...  # just those
#
# NWP-20261027-21: the Diaspore twin editions/diaspore/build/patches/trebuchet-media-progress-ring.sh (applied by
# apply-patches.sh as `bash <script> <tree>`) runs through the same cases (a)-(f) on a tree under
# packages/apps/Trebuchet/...; (g) compares the five device copies only, the twin is not one. Its mutants are T1-T3e.
set -uo pipefail

MUTATE=no; SUTS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUTS+=("$a") ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVS=(lynx frankel stallion tegu husky)
RING=launcher3-media-progress-ring.sh
TREB="$HERE/../../diaspore/build/patches/trebuchet-media-progress-ring.sh"
if [ ${#SUTS[@]} = 0 ]; then for d in "${DEVS[@]}"; do SUTS+=("$HERE/../devices/$d/patches/$RING"); done; SUTS+=("$TREB"); fi

for t in patch python3; do command -v "$t" >/dev/null || { echo "FAIL  $t is required"; exit 2; }; done
v=$(patch --version 2>&1); echo "${v%%$'\n'*}"
python3 --version

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q`.
has(){ grep -cF -- "$2" "$1" >/dev/null; }
same(){ diff -r "$1" "$2" >/dev/null 2>&1; }
srcrel_of(){ case "$(basename "$1")" in trebuchet-*) echo packages/apps/Trebuchet/src/com/android/launcher3 ;; *) echo packages/apps/Launcher3/src/com/android/launcher3 ;; esac; }
label_of(){ case "$(basename "$1")" in trebuchet-*) echo trebuchet ;; *) basename "$(dirname "$(dirname "$1")")" ;; esac; }

# extract <sut> <outdir> <srcrel>: <outdir>/{btv,launcher,dsbtv}.diff, dsbtv_inner and the pristine fixture tree, all
# built from the hunks in the script under test.
extract(){
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, os, re, sys
sut, out, srcrel = sys.argv[1:4]
s = io.open(sut, encoding='utf-8').read()
def fail(what):
    print("EXTRACTION FAILED: " + what); sys.exit(2)
found = re.findall(r"<<'(PATCH_\w+)'\n(.*?)\n\1\n", s, re.S)
names = sorted(n for n, _ in found)
if names != ['PATCH_BTV', 'PATCH_DSBTV', 'PATCH_LAUNCHER']: fail("the three heredocs, got %r" % names)
src = os.path.join(out, 'tree', srcrel)
short = {'PATCH_BTV': 'btv', 'PATCH_LAUNCHER': 'launcher', 'PATCH_DSBTV': 'dsbtv'}
for name, body in found:
    io.open(os.path.join(out, short[name] + '.diff'), 'w', encoding='utf-8', newline='\n').write(body + "\n")
    lines = body.split("\n")
    m = re.match(r"--- (\S+)", lines[0])
    if not m: fail(name + " has no --- line")
    hunks, cur = [], None
    for l in lines[2:]:
        if l.startswith('@@'): cur = []; hunks.append(cur)
        elif cur is None: fail(name + " has text before its first @@")
        elif l[:1] in (' ', '-'): cur.append(l[1:])
        elif l[:1] == '+': pass
        elif l == '': cur.append('')
        else: fail(name + " has an unreadable hunk line")
    if not hunks or not all(hunks): fail(name + " has no hunk")
    text = ["class X {"] + ["    filler lead %d;" % i for i in range(4)]
    for k, h in enumerate(hunks):
        if k: text += ["    filler between %d;" % i for i in range(3)]
        text += h
    text += ["    filler tail %d;" % i for i in range(4)] + ["}"]
    path = os.path.join(src, m.group(1))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    io.open(path, 'w', encoding='utf-8', newline='\n').write("\n".join(text) + "\n")
# the DSBTV hunk's innermost leading context line, for the drift case
d = [b for n, b in found if n == 'PATCH_DSBTV'][0].split("\n")
plus = [i for i, l in enumerate(d) if l.startswith('+') and not l.startswith('+++')]
if not plus or not d[plus[0] - 1].startswith(' '): fail("DSBTV inner context line")
io.open(os.path.join(out, 'dsbtv_inner'), 'w', encoding='utf-8', newline='\n').write(d[plus[0] - 1][1:])
PY
}
newtree(){ local t; t=$(mktemp -d -p "$W") || exit 2; cp -r "$1/tree/." "$t"; echo "$t"; }
snap(){ local t; t=$(mktemp -d -p "$W") || exit 2; cp -r "$1/." "$t"; echo "$t"; }
# run <sut> <tree> <tag>: the script's exit code; output in $W/<tag>.out / .err
run(){ bash "$1" "$2" </dev/null >"$W/$3.out" 2>"$W/$3.err"; echo $?; }
# half <extract dir> <tree> both|launcher: patch the fixture the way a stopped run leaves it, minus the backups
half(){
  local ex="$1" t="$2" which="$3"
  ( cd "$t/$SRCREL" || exit 1
    if [ "$which" = both ]; then patch -p0 --fuzz=3 -s < "$ex/btv.diff" >/dev/null || exit 1; fi
    patch -p0 --fuzz=3 -s < "$ex/launcher.diff" >/dev/null || exit 1
    find . -name '*.orig' -delete ) || return 1
}

# cases <sut> <label>
cases(){
  local sut="$1" label="$2" ex t s rc inner x SRCREL
  SRCREL=$(srcrel_of "$sut")
  ex=$(mktemp -d -p "$W") || exit 2
  x=$(extract "$sut" "$ex" "$SRCREL") || { no "$label: $x"; return; }
  # (a) pristine
  t=$(newtree "$ex"); rc=$(run "$sut" "$t" a)
  if [ "$rc" = 0 ] && has "$W/a.out" "applied + verified" \
     && has "$t/$SRCREL/BubbleTextView.java" drawMediaRingIfNecessary \
     && has "$t/$SRCREL/views/DoubleShadowBubbleTextView.java" drawMediaRingIfNecessary \
     && has "$t/$SRCREL/Launcher.java" app.nowhere.MEDIA_PROGRESS; then ok "$label (a) pristine applies + verifies"
  else no "$label (a) pristine applies + verifies (exit $rc)"; fi
  # (b) re-run
  s=$(snap "$t"); rc=$(run "$sut" "$t" b)
  if [ "$rc" = 0 ] && has "$W/b.out" "already applied" && same "$t" "$s"; then ok "$label (b) re-run is already applied, tree unchanged"
  else no "$label (b) re-run is already applied, tree unchanged (exit $rc)"; fi
  # (c) DSBTV drifted
  t=$(newtree "$ex"); inner=$(cat "$ex/dsbtv_inner")
  if ! python3 -I - "$t/$SRCREL/views/DoubleShadowBubbleTextView.java" "$inner" <<'PY'
import io, sys
p, line = sys.argv[1:3]
L = io.open(p, encoding='utf-8').read().split("\n")
i = [k for k, l in enumerate(L) if l == line]
if len(i) != 1: sys.exit(2)
L[i[0]] = "        renamedByUpstream(canvas);"
io.open(p, 'w', encoding='utf-8', newline='\n').write("\n".join(L))
PY
  then no "$label (c) could not drift the DSBTV fixture"
  else
    s=$(snap "$t"); rc=$(run "$sut" "$t" c)
    if [ "$rc" = 2 ] && has "$W/c.err" DoubleShadowBubbleTextView && same "$t" "$s"; then ok "$label (c) drifted DSBTV: exit 2, nothing written"
    else no "$label (c) drifted DSBTV (exit $rc, want 2 and an untouched tree)"; fi
  fi
  # (d) BTV + Launcher patched, DSBTV pristine
  t=$(newtree "$ex")
  if ! half "$ex" "$t" both; then no "$label (d) setup"; else
    s=$(snap "$t"); rc=$(run "$sut" "$t" d)
    if [ "$rc" = 3 ] && has "$W/d.err" HALF-APPLIED && has "$W/d.err" DoubleShadowBubbleTextView && same "$t" "$s"; then ok "$label (d) half-applied: exit 3, nothing written"
    else no "$label (d) half-applied (exit $rc, want 3 and an untouched tree)"; fi
  fi
  # (e) only Launcher patched
  t=$(newtree "$ex")
  if ! half "$ex" "$t" launcher; then no "$label (e) setup"; else
    s=$(snap "$t"); rc=$(run "$sut" "$t" e)
    if [ "$rc" = 3 ] && same "$t" "$s"; then ok "$label (e) only Launcher patched: exit 3, nothing written"
    else no "$label (e) only Launcher patched (exit $rc, want 3 and an untouched tree)"; fi
  fi
  # (f) missing DSBTV file (moved aside outside the tree, never deleted by path expansion)
  t=$(newtree "$ex"); mv "$t/$SRCREL/views/DoubleShadowBubbleTextView.java" "$ex/gone.java"
  s=$(snap "$t"); rc=$(run "$sut" "$t" f)
  if [ "$rc" = 1 ] && same "$t" "$s"; then ok "$label (f) missing DSBTV file: exit 1, nothing written"
  else no "$label (f) missing DSBTV file (exit $rc, want 1 and an untouched tree)"; fi
}

# (g) the copies are identical below line 2
identical(){
  local first="$1" p bad=""
  for p in "$@"; do
    diff <(tail -n +3 "$first") <(tail -n +3 "$p") >/dev/null || bad="$bad $p"
  done
  if [ -z "$bad" ]; then ok "(g) the copies are identical below line 2"; else no "(g) copies differ below line 2:$bad"; fi
}

runall(){
  local i p dev=()
  for i in "${!SUTS[@]}"; do
    cases "${SUTS[$i]}" "$(label_of "${SUTS[$i]}")"
  done
  for p in "${SUTS[@]}"; do [ "$(basename "$p")" = "$RING" ] && dev+=("$p"); done
  if [ ${#dev[@]} -gt 1 ]; then identical "${dev[@]}"; fi
  return 0
}

runall

# --- mutants: each edits copies under $W and must turn a named case red ---------------------------------------
if [ "$MUTATE" = yes ]; then
  echo "== mutants"
  M=$(mktemp -d -p "$W") || exit 2
  # mutant <name> <sed expr> <all|last> <case regex that must show a FAIL line>
  mutant(){
    local name="$1" expr="$2" scope="$3" want="$4" d i p mp pass0 fail0 log sp=()
    for d in "${DEVS[@]}"; do mkdir -p "$M/$name/$d/patches"; cp "$HERE/../devices/$d/patches/$RING" "$M/$name/$d/patches/$RING"; done
    for i in "${!DEVS[@]}"; do
      p="$M/$name/${DEVS[$i]}/patches/$RING"
      if [ "$scope" = all ] || [ "$i" = $((${#DEVS[@]}-1)) ]; then
        mp=$(mktemp -p "$W"); sed -E "$expr" "$p" > "$mp" && cat "$mp" > "$p"
        if cmp -s "$p" "$HERE/../devices/${DEVS[$i]}/patches/$RING"; then no "mutant $name did not change ${DEVS[$i]}"; return; fi
      fi
      sp+=("$p")
    done
    pass0=$PASS; fail0=$FAIL; log="$W/$name.log"
    SUTS=("${sp[@]}"); runall > "$log" 2>&1
    PASS=$pass0; FAIL=$fail0
    if grep -E "FAIL  .*$want" "$log" >/dev/null; then ok "mutant $name convicted by $want"
    else no "mutant $name SURVIVED (no red $want)"; fi
  }
  # R1 the classification reduced to the first-file marker
  mutant R1 '/^mark (Launcher.java|views\/DoubleShadowBubbleTextView.java) /d' all '\(d\)'
  # R2 the dry-run of the DSBTV hunk skipped
  mutant R2 '/^dryrun views\/DoubleShadowBubbleTextView.java /d' all '\(c\)'
  # R3 the half-applied branch exits 0
  mutant R3 's/^  exit 3$/  exit 0/' all '\(d\)'
  mutant R3e 's/^  exit 3$/  exit 0/' all '\(e\)'
  # R4 one copy's guard differs
  mutant R4 's/already applied"; exit 0/already patched"; exit 0/' last '\(g\)'
  # R5 the anchor check skipped, leaving the DSBTV hunk to --fuzz=3, which places it by line number alone
  mutant R5 's/^  anchor "\$1" "\$2"$/  :/' all '\(c\)'
  # tmutant <name> <sed expr> <case regex>: the same mutation applied to the Trebuchet twin (NWP-20261027-21)
  tmutant(){
    local name="$1" expr="$2" want="$3" p mp pass0 fail0 log
    mkdir -p "$M/$name"; p="$M/$name/trebuchet-media-progress-ring.sh"
    mp=$(mktemp -p "$W"); sed -E "$expr" "$TREB" > "$mp" && cat "$mp" > "$p"
    if cmp -s "$p" "$TREB"; then no "mutant $name did not change the Trebuchet copy"; return; fi
    pass0=$PASS; fail0=$FAIL; log="$W/$name.log"
    SUTS=("$p"); runall > "$log" 2>&1
    PASS=$pass0; FAIL=$fail0
    if grep -E "FAIL  trebuchet $want" "$log" >/dev/null; then ok "mutant $name convicted by trebuchet $want"
    else no "mutant $name SURVIVED (no red trebuchet $want)"; fi
  }
  tmutant T1 '/^mark (Launcher.java|views\/DoubleShadowBubbleTextView.java) /d' '\(d\)'
  tmutant T2 '/^dryrun views\/DoubleShadowBubbleTextView.java /d' '\(c\)'
  tmutant T3 's/^  exit 3$/  exit 0/' '\(d\)'
  tmutant T3e 's/^  exit 3$/  exit 0/' '\(e\)'
fi

echo "== $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
