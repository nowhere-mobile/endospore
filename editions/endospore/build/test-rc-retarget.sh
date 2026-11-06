#!/usr/bin/env bash
# test-rc-retarget.sh [<stage-vendor.sh>] [--mutate] -- the Endospore stage's rc retarget, file_contexts generator and
# harvest gate, and the order of the rc's boot_completed block, run against the real files.
#
# WHY THIS IS COMMITTED (NWP-20261107-09). Nothing executed these. The seclabel retarget maps nowhere_mediad to
# endospore_mediad and every other su:s0 worker to endospore_priv, and its only guard (a surviving u:r:su:s0) cannot
# see a WRONG domain: nowhere_mediad in endospore_priv holds no CAP_SYS_ADMIN, cannot mount, the denial is dontaudit-ed
# and on-demand media dies with no build break (DIA-20260806-09 was the same silence one layer down: a hand list that
# missed nowhere_mediad.sh). The harvest gate is what keeps a permissive domain out of a release image. And the rc's
# `on property:sys.boot_completed=1` block must mount the tmpfs before any `start`, and every service must be `disabled`
# (else `class late_start` starts it before the mount): .roamsession (name and passphrase), roam.req and the wallet
# would land on durable f2fs with no build break.
#
# The stage block (from the nowhere.rc retarget through the NOWHERE_SEPOLICY_HARVEST fi) is extracted from the real
# stage-vendor.sh BY ANCHOR and run on a scratch DEST holding a copy of the real rc, file_contexts and the two real
# Endospore .te files; if an anchor moves the suite exits 2.
#
#   bash test-rc-retarget.sh                  # the cases against the real stage-vendor.sh and nowhere.rc
#   bash test-rc-retarget.sh <stage-vendor>   # ... against another copy of the stage (RC_SRC=<rc> likewise for the rc)
#   bash test-rc-retarget.sh --mutate         # ... plus broken copies that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SV=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SV="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
REAL_SV="$HERE/stage-vendor.sh"
SV="${SV:-$REAL_SV}"
RC_SRC="${RC_SRC:-$ROOT/core/vendor-common/etc/nowhere.rc}"
FC_SRC="$ROOT/core/vendor-common/sepolicy/file_contexts"
TE_DIR="$ROOT/editions/endospore/vendor/sepolicy"
for f in "$SV" "$RC_SRC" "$FC_SRC" "$TE_DIR/endospore.te" "$TE_DIR/endospore_mediad.te"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 -- [$3] present in: $2" ;; *) ok "$1" ;; esac; }

BLK="$W/stage.block"
awk '
  !on && $0 == "if [ -f \"$DEST/etc/nowhere.rc\" ]; then" { on = 1 }
  on { print }
  on && index($0, "NOWHERE_SEPOLICY_HARVEST:-0") { seen = 1 }
  on && seen && $0 == "fi" { exit }
' "$SV" > "$BLK"
B=$(cat "$BLK")
for k in endospore_mediad 'survives the retarget' LABELLED HARVEST_DST; do
  case "$B" in *"$k"*) ;; *) echo "EXTRACTION FAILED -- [$k] not in the stage block extracted from $SV" >&2; exit 2 ;; esac
done

# newrepo -> a scratch REPO holding the harvest source
newrepo(){
  local r; r=$(mktemp -d -p "$W")
  mkdir -p "$r/editions/endospore/build/harvest"
  printf 'permissive endospore_mediad;\n' > "$r/editions/endospore/build/harvest/endospore_mediad_permissive.te"
  printf '%s' "$r"
}
# newdest <rc> -> a scratch DEST holding that rc, the real core file_contexts and the two real Endospore .te files
newdest(){
  local d; d=$(mktemp -d -p "$W")
  mkdir -p "$d/etc" "$d/sepolicy"
  cp "$1" "$d/etc/nowhere.rc"; cp "$FC_SRC" "$d/sepolicy/file_contexts"
  cp "$TE_DIR/endospore.te" "$TE_DIR/endospore_mediad.te" "$d/sepolicy/"
  printf '%s' "$d"
}
# stage <repo> <dest> [VAR=val ...] -> sets RC and OUTP (stdout+stderr)
stage(){
  local repo="$1" dest="$2" s; s=$(mktemp -p "$W"); shift 2
  { printf 'set -euo pipefail\nREPO=%q; DEST=%q\n' "$repo" "$dest"; cat "$BLK"; } > "$s"
  OUTP=$(env -u NOWHERE_SEPOLICY_HARVEST "$@" bash "$s" 2>&1); RC=$?
}
# pairs <rc> -> "service seclabel" per stanza
pairs(){ awk '/^service /{svc=$2} /^[ \t]+seclabel /{print svc, $2}' "$1"; }
# fcadded <before> <after> -> the labels added (comments dropped), "path type" each, sorted
fcadded(){ diff "$1" "$2" | sed -n 's/^> //p' | grep -v '^#' | awk '{print $1, $2}' | sort; }

R=$(newrepo)

echo "== (a)-(d) the retarget on the real rc =="
D=$(newdest "$RC_SRC"); stage "$R" "$D"
is "(a) retarget: exit 0" "$RC" 0
GOT=$(pairs "$D/etc/nowhere.rc")
WANT="nowhere_login u:r:nowhere:s0
nowhere_provision u:r:endospore_priv:s0
nowhere_roamd u:r:endospore_priv:s0
nowhere_roamd_ro u:r:endospore_priv:s0
nowhere_roamd_cred u:r:endospore_priv:s0
nowhere_otad u:r:endospore_priv:s0
nowhere_mediad u:r:endospore_mediad:s0
nowhere_gate u:r:endospore_priv:s0"
is "(b) retarget: each stanza's seclabel" "$GOT" "$WANT"
is "(c) retarget: nothing left in su:s0" "$(grep -c 'u:r:su:s0' "$D/etc/nowhere.rc")" 0
is "(d) retarget: every other rc line is the source's" \
  "$(grep -v 'seclabel ' "$D/etc/nowhere.rc" | cksum)" "$(grep -v 'seclabel ' "$RC_SRC" | cksum)"
is "(d) retarget: same number of lines" "$(wc -l < "$D/etc/nowhere.rc")" "$(wc -l < "$RC_SRC")"

echo "== (e) a service added after mediad is retargeted =="
SYN="$W/syn.rc"
{ cat "$RC_SRC"; printf '\nservice nowhere_newd /system/bin/nowhere_newd.sh\n    class late_start\n    user root\n    group root\n    oneshot\n    disabled\n    seclabel u:r:su:s0\n'; } > "$SYN"
D=$(newdest "$SYN"); stage "$R" "$D"
is "(e) new service: exit 0" "$RC" 0
is "(e) new service: endospore_priv" "$(pairs "$D/etc/nowhere.rc" | sed -n 's/^nowhere_newd //p')" "u:r:endospore_priv:s0"

echo "== (f) a seclabel the retarget cannot match fails the build =="
SYN="$W/two-space.rc"
{ cat "$RC_SRC"; printf '\nservice nowhere_oddd /system/bin/nowhere_oddd.sh\n    class late_start\n    disabled\n    seclabel  u:r:su:s0\n'; } > "$SYN"
D=$(newdest "$SYN"); stage "$R" "$D"
is "(f) two-space seclabel: exit 1" "$RC" 1
has "(f) two-space seclabel: names the survivor" "$OUTP" "u:r:su:s0 survives the retarget"

echo "== (g)-(i) the file_contexts generator =="
D=$(newdest "$RC_SRC"); stage "$R" "$D"
GOT=$(fcadded "$FC_SRC" "$D/sepolicy/file_contexts")
WANT='/system/bin/nowhere_gate\.sh u:object_r:endospore_priv_exec:s0
/system/bin/nowhere_mediad\.sh u:object_r:endospore_mediad_exec:s0
/system/bin/nowhere_otad\.sh u:object_r:endospore_priv_exec:s0
/system/bin/nowhere_provision\.sh u:object_r:endospore_priv_exec:s0
/system/bin/nowhere_roamd\.sh u:object_r:endospore_priv_exec:s0'
is "(g) generator: exactly the five labels, dots escaped" "$GOT" "$WANT"
hasnt "(g) generator: nothing for nowhere_login.sh" "$(diff "$FC_SRC" "$D/sepolicy/file_contexts")" "nowhere_login"
cp "$D/sepolicy/file_contexts" "$W/fc.once"
stage "$R" "$D"
is "(h) generator: second run exit 0" "$RC" 0
cmp -s "$W/fc.once" "$D/sepolicy/file_contexts" && ok "(h) generator: second run adds nothing" || no "(h) generator: second run changed file_contexts"
D=$(newdest "$RC_SRC"); rm -f "$D/sepolicy/endospore_mediad.te"; stage "$R" "$D"
is "(i) undeclared domain: exit 1" "$RC" 1
has "(i) undeclared domain: says so" "$OUTP" "no staged .te declares that domain"

echo "== (j)-(l) the harvest gate =="
HS="$R/editions/endospore/build/harvest/endospore_mediad_permissive.te"
D=$(newdest "$RC_SRC"); printf 'stale\n' > "$D/sepolicy/endospore_mediad_permissive.te"; stage "$R" "$D"
is "(j) harvest unset: exit 0" "$RC" 0
[ ! -e "$D/sepolicy/endospore_mediad_permissive.te" ] && ok "(j) harvest unset: the stale permissive .te is removed" || no "(j) harvest unset: a stale permissive .te survived"
hasnt "(j) harvest unset: no banner" "$OUTP" "must never ship"
D=$(newdest "$RC_SRC"); printf 'stale\n' > "$D/sepolicy/endospore_mediad_permissive.te"; stage "$R" "$D" NOWHERE_SEPOLICY_HARVEST=1
is "(k) harvest=1: exit 0" "$RC" 0
cmp -s "$HS" "$D/sepolicy/endospore_mediad_permissive.te" && ok "(k) harvest=1: the source is copied" || no "(k) harvest=1: the .te is not the source"
has "(k) harvest=1: the banner" "$OUTP" "this image must never ship"
R2=$(mktemp -d -p "$W"); D=$(newdest "$RC_SRC"); stage "$R2" "$D" NOWHERE_SEPOLICY_HARVEST=1
is "(l) harvest=1, source missing: exit 1" "$RC" 1
has "(l) harvest=1, source missing: says so" "$OUTP" "is missing"

echo "== (m)-(o) the source rc's boot ordering =="
BOOT=$(awk '
  /^on /      { inb = ($0 == "on property:sys.boot_completed=1"); next }
  /^[ \t]*#/  { next }
  /^[^ \t]/   { inb = 0 }
  inb && /^[ \t]+[^ \t]/ { print }
' "$RC_SRC")
WANT='    mkdir /data/nowhere 0700 root root
    mkdir /data/nowhere/state 0700 root root
    mount tmpfs tmpfs /data/nowhere/state mode=0700,size=256m,context=u:object_r:nowhere_data_file:s0
    start nowhere_gate
    start nowhere_login
    start nowhere_provision'
is "(m) boot_completed block: the six commands, in order" "$BOOT" "$WANT"
is "(m) boot_completed block: the mount comes before every start" \
  "$(printf '%s\n' "$BOOT" | awk '/^ +mount /{m=1} /^ +start /{if(!m)bad++} END{print bad+0}')" 0
is "(n) every service is disabled" \
  "$(awk '/^service /{ if (s != "" && !d) print s; s=$2; d=0; next } /^[ \t]+disabled[ \t]*$/{d=1} END{ if (s != "" && !d) print s }' "$RC_SRC" | tr '\n' ' ')" ""
is "(o) no other trigger starts a nowhere service" \
  "$(awk '/^on /{ other = ($0 != "on property:sys.boot_completed=1"); next } /^[^ \t#]/{ other = 1 } !/^[ \t]*#/ && other && /^[ \t]+(start|setprop ctl\.start)[ \t]+nowhere_/{print}' "$RC_SRC")" ""

# --- --mutate: each broken copy must fail the suite in the cases it names (rc 1 -- not an extraction exit) -------
if [ "$MUTATE" = yes ]; then
  echo "== mutations =="
  SELF="$HERE/$(basename "$0")"
  # mutate <label> <cases> <stage|rc> <old> <new> [<old> <new> ...]: replace the first <old> of each pair in a copy.
  # Convicted only by rc 1 AND a "FAIL  (<x>)" line in the copy's run for every case letter <x> in <cases>, so an
  # unrelated case or a setup failure that exits 1 is not scored as this mutant's conviction.
  mutate(){
    local label="$1" cases="$2" kind="$3" m rc c miss=""; shift 3
    m=$(mktemp -p "$W")
    if [ "$kind" = stage ]; then SRC="$REAL_SV"; else SRC="$ROOT/core/vendor-common/etc/nowhere.rc"; fi
    python3 -I - "$SRC" "$m" "$@" <<'PY'
import sys
src, dst = sys.argv[1:3]
rest = sys.argv[3:]
s = open(src).read()
for old, new in zip(rest[0::2], rest[1::2]):
    if old not in s:
        sys.exit(3)
    s = s.replace(old, new, 1)
open(dst, "w").write(s)
PY
    rc=$?
    if [ "$rc" -ne 0 ]; then no "mutation '$label' did not apply"; return; fi
    if [ "$kind" = stage ]; then bash "$SELF" "$m" > "$W/mut.out" 2>&1; rc=$?
    else RC_SRC="$m" bash "$SELF" > "$W/mut.out" 2>&1; rc=$?; fi
    case "$rc" in
      1) for c in $cases; do grep -qF "  FAIL  ($c) " "$W/mut.out" || miss="$miss ($c)"; done
         if [ -z "$miss" ]; then ok "mutation convicted by ($cases): $label"
         else no "mutation '$label' exited 1 but did not FAIL$miss"; fi ;;
      0) no "mutation SURVIVED: $label" ;;
      *) no "mutation '$label' hit an extraction/setup exit (rc $rc), not a conviction" ;;
    esac
  }
  mutate "M1: mediad is matched by another name" "b g" stage \
    'svc == "nowhere_mediad"' 'svc == "nowhere_mediadX"'
  mutate "M2: the survivor check is removed" f stage \
    "if grep -q 'u:r:su:s0' \"\$DEST/etc/nowhere.rc\"; then" 'if false; then'
  mutate "M3: the sub is applied to every seclabel line" "b g" stage \
    '/seclabel u:r:su:s0/ { dom' '/seclabel u:r:/ { dom' \
    'sub(/u:r:su:s0/,' 'sub(/u:r:[a-z_]+:s0/,'
  mutate "M4: the count check is removed and the mediad entrypoint skipped" g stage \
    'for s in $DOM_SCRIPTS; do' 'for s in $(echo "$DOM_SCRIPTS" | grep -v mediad); do' \
    '[ "$LABELLED" -eq "$WANTED" ] || {' 'true || {'
  mutate "M5: the stale permissive .te is no longer removed" j stage \
    'rm -f "$HARVEST_DST"' ':'
  mutate "M6: start nowhere_login moves above the mount" m rc \
    '    mount tmpfs tmpfs' '    start nowhere_login
    mount tmpfs tmpfs'
  mutate "M7: the tmpfs mount loses context=" m rc \
    ',context=u:object_r:nowhere_data_file:s0' ''
  mutate "M8: nowhere_login loses disabled" n rc \
    '    seclabel u:r:nowhere:s0
    disabled' '    seclabel u:r:nowhere:s0'
fi

echo
echo "test-rc-retarget: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
