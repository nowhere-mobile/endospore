#!/usr/bin/env bash
# test-patch-endstate.sh [--mutate] [<patch script>...] -- NWP-20261011-15.
#
# WHY THIS IS COMMITTED. launcher3-grid.sh and launcher3-qsb-firstscreen.sh (one copy per Endospore device) and
# build/patches/recovery-rebrand.sh edit trees we do not own, and build-device.sh fails the build only when a patch
# exits non-zero. Until NWP-20261011-15 these three could not: their seds exit 0 whether or not they matched, and
# each printed success (qsb printed "already true (or default moved)"), so an upstream sync that moved an anchor
# shipped a green build with the behaviour gone. Each now asserts its end state and exits 2 with a "DRIFT:" line.
# These checks run every copy against synthetic trees -- pristine -> 0 and the end state reached, re-run -> 0,
# drifted anchor -> 2 -- and pin that the five device copies of each launcher script differ only in their header
# line 2. They cannot show that the anchors still match the real GrapheneOS tree; that is checked on the build host
# (the register in docs/framework-patches.md says how). CI executes this suite and its --mutate run. Plain bash.
#
#   bash test-patch-endstate.sh                 # every device copy + recovery-rebrand.sh + endospore-{brand,attest}-strings.sh (NWP-20261013-29)
#   bash test-patch-endstate.sh --mutate        # ... plus mutations that must each CONVICT the suite
#   bash test-patch-endstate.sh <script>...     # just those (the kind is inferred from the basename)
set -uo pipefail

MUTATE=no; SUTS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUTS+=("$a") ;; esac; done
ED="$(cd "$(dirname "$0")/.." && pwd)"   # editions/endospore
DEVICES="lynx frankel stallion tegu husky"
if [ ${#SUTS[@]} = 0 ]; then
  DEFAULT_LIST=yes
  for d in $DEVICES; do SUTS+=("$ED/devices/$d/patches/launcher3-grid.sh"); done
  for d in $DEVICES; do SUTS+=("$ED/devices/$d/patches/launcher3-qsb-firstscreen.sh"); done
  SUTS+=("$ED/build/patches/recovery-rebrand.sh")
  SUTS+=("$ED/build/patches/endospore-brand-strings.sh" "$ED/build/patches/endospore-attest-strings.sh")
else DEFAULT_LIST=no; fi

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).
kind(){ case "$(basename "$1")" in launcher3-grid.sh) echo grid ;; launcher3-qsb-firstscreen.sh) echo qsb ;; recovery-rebrand.sh) echo rec ;; endospore-brand-strings.sh) echo brand ;; endospore-attest-strings.sh) echo attest ;; *) echo unknown ;; esac; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
DP=packages/apps/Launcher3/res/xml/device_profiles.xml
BC=packages/apps/Launcher3/tools/buildconfig.sh
RC=bootable/recovery/recovery.cpp
FB=bootable/recovery/fastboot/fastboot.cpp
FRW=frameworks/base/core/res/res/values/strings.xml
FRWMAN=frameworks/base/core/res/AndroidManifest.xml
SEX=packages/apps/Settings/res/values/strings_ext.xml
AEP=packages/apps/Settings/res/values/strings_app_exploit_protection.xml
ICON=frameworks/base/core/res/res/drawable-anydpi-v21/ic_launcher_android.xml
# brand-strings copies this icon; the mutated copies run from a temp dir, so name the source explicitly.
export NOWHERE_SPORE_SRC="$ED/vendor/chooser/res/drawable/ic_nowhere.xml"

# run <sut> <tree>: run the script on $W/<tree>, output to $W/<tree>.out, echo its exit code.
run(){ bash "$1" "$W/$2" > "$W/$2.out" 2>&1; echo $?; }
said(){ grep -cF -- "$2" "$W/$1.out" >/dev/null; }
has(){ grep -cF -- "$2" "$1" >/dev/null; }
lacks(){ ! grep -cF -- "$2" "$1" >/dev/null; }
same(){ cmp -s "$1" "$2"; }
# The Pixel 2021 block, extracted with the same scoped range the patch uses.
pblock(){ sed -n '/launcher:name="Pixel 2021"/,/\/>/p' "$1"; }
# The Large Phone block: the sed's range must not reach it.
lblock(){ sed -n '/launcher:name="Large Phone"/,/\/>/p' "$1"; }

# --- fixtures -------------------------------------------------------------------------------------------
tree_grid(){   # <name> pristine|renamed|icon58|quoted  (the 2026-06 shape: a 4x5 "Pixel 2021" beside the 5x5 "Large Phone")
  mkdir -p "$W/$1/$(dirname "$DP")"
  local p21='Pixel 2021' icon=56
  [ "$2" = renamed ] && p21='Pixel 2022'
  [ "$2" = icon58 ] && icon=58
  local p21cbd='launcher:canBeDefault="true"'
  [ "$2" = quoted ] && p21cbd="launcher:canBeDefault='true'"   # the sed's anchor cannot match it
  cat > "$W/$1/$DP" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<profiles xmlns:launcher="http://schemas.android.com/apk/res-auto">
    <grid-option launcher:name="4_by_5" launcher:numRows="5" launcher:numColumns="4">
        <display-option
            launcher:name="$p21"
            launcher:minWidthDps="380"
            launcher:minHeightDps="740"
            launcher:iconImageSize="60"
            $p21cbd />
    </grid-option>
    <grid-option launcher:name="5_by_5" launcher:numRows="5" launcher:numColumns="5">
        <display-option
            launcher:name="Large Phone"
            launcher:minWidthDps="406"
            launcher:minHeightDps="694"
            launcher:iconImageSize="$icon"
            launcher:canBeDefault="true" />
    </grid-option>
</profiles>
EOF
}
# tree_stock <name> pristine|grid4x5|nodefault|otherlist -- the GrapheneOS 2026110100 shape (NWP-20261104-26): res/ has
# a 4x4 grid and the 5x5 "Large Phone", no "Pixel 2021", and res-stock/xml/device_profiles.xml (the stock Pixel grids)
# overrides it unless the patch removes it. grid4x5: a 4x5 default candidate under another name; nodefault: "Large
# Phone" is not a default candidate; otherlist: a second grid list in quickstep/res, which the patch does not remove.
tree_stock(){
  local L="$W/$1/packages/apps/Launcher3" cbd=true four=4
  [ "$2" = nodefault ] && cbd=false
  [ "$2" = grid4x5 ] && four=5
  mkdir -p "$L/res/xml" "$L/res-stock/xml"
  cat > "$L/res/xml/device_profiles.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<profiles xmlns:launcher="http://schemas.android.com/apk/res-auto">
    <grid-option
        launcher:name="4_by_$four"
        launcher:numRows="$four"
        launcher:numColumns="4" >
        <display-option
            launcher:name="Nexus 5"
            launcher:minWidthDps="335"
            launcher:minHeightDps="567"
            launcher:canBeDefault="true" />
    </grid-option>
    <grid-option
        launcher:name="5_by_5"
        launcher:numRows="5"
        launcher:numColumns="5" >
        <display-option
            launcher:name="Large Phone"
            launcher:minWidthDps="406"
            launcher:minHeightDps="694"
            launcher:iconImageSize="56"
            launcher:canBeDefault="$cbd" />
    </grid-option>
</profiles>
EOF
  printf '<profiles><grid-option launcher:name="small" launcher:numColumns="5" /></profiles>\n' > "$L/res-stock/xml/device_profiles.xml"
  if [ "$2" = otherlist ]; then mkdir -p "$L/quickstep/res/xml"; cp "$L/res-stock/xml/device_profiles.xml" "$L/quickstep/res/xml/"; fi
  mkdir -p "$L/go/quickstep/res/xml"; cp "$L/res-stock/xml/device_profiles.xml" "$L/go/quickstep/res/xml/"   # ignored: Launcher3Go
}
tree_qsb(){    # <name> pristine|quoted|missing
  mkdir -p "$W/$1/$(dirname "$BC")"
  {
    echo '#!/bin/bash'
    echo 'WIDGET_ON_FIRST_SCREEN = ${overrides[WIDGET_ON_FIRST_SCREEN]:-false}'
    case "$2" in
      pristine) echo 'QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-false}' ;;
      quoted)   echo 'QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-"false"}' ;;
      missing)  : ;;
    esac
    echo 'echo done'
  } > "$W/$1/$BC"
}
tree_rec(){    # <name> pristine|fastboot-drift|recovery-drift|no-fastboot
  mkdir -p "$W/$1/$(dirname "$FB")"
  local r='GrapheneOS Recovery' f='GrapheneOS Fastboot'
  [ "$2" = recovery-drift ] && r='GrapheneOS recovery'
  [ "$2" = fastboot-drift ] && f='GrapheneOS fastboot'
  printf 'static const char* kTitle = "%s";\nint main() { return 0; }\n' "$r" > "$W/$1/$RC"
  if [ "$2" = no-fastboot ]; then rmdir "$W/$1/$(dirname "$FB")"
  else printf 'void Init() { title = "%s"; }\n' "$f" > "$W/$1/$FB"; fi
}

tree_brand(){  # <name> pristine|label|abi|duress|applabel
  mkdir -p "$W/$1/$(dirname "$FRW")" "$W/$1/$(dirname "$SEX")"
  local sl='Android System' abi='GrapheneOS plans to phase out' du='GrapheneOS will remain installed' al='GrapheneOS'
  [ "$2" = label ] && sl='System'
  [ "$2" = abi ] && abi='GrapheneOS will phase out'
  [ "$2" = duress ] && du='GrapheneOS stays installed'
  [ "$2" = applabel ] && al='Other'
  printf '<resources>\n<string name="android_system_label">%s</string>\n<string name="m">%s 32-bit apps</string>\n</resources>\n' "$sl" "$abi" > "$W/$1/$FRW"
  printf '<manifest><application android:label="%s" /></manifest>\n' "$al" > "$W/$1/$FRWMAN"
  printf '<resources>\n<string name="d">%s</string>\n<string name="p">GrapheneOS proxy</string>\n</resources>\n' "$du" > "$W/$1/$SEX"
}
tree_attest(){ # <name> pristine|reworded|clean
  mkdir -p "$W/$1/$(dirname "$SEX")"
  local a='GrapheneOS server' b='GrapheneOS exploit protection'
  [ "$2" = reworded ] && { a='the server'; b='exploit protection'; }
  [ "$2" = clean ] && { a='endospore server'; b='endospore exploit protection'; }
  printf '<resources>\n<string name="a">%s</string>\n</resources>\n' "$a" > "$W/$1/$SEX"
  printf '<resources>\n<string name="b">%s</string>\n</resources>\n' "$b" > "$W/$1/$AEP"
}

# usage <sut> <tree line> <usage text>: the no-argument case, run only once the tree line is the pinned one.
usage(){
  local n; n=$(grep -c '^TREE=' "$1")
  if [ "$n" = 1 ] && grep -cxF -- "$2" "$1" >/dev/null; then
    mkdir -p "$W/empty"
    ( cd "$W/empty" && bash "$1" ) > "$W/noarg.out" 2>&1; local rc=$?
    if [ "$rc" = 1 ] && said noarg "$3"; then ok "no argument: exit 1 with the usage line"; else no "no argument: exit $rc, or no usage line"; fi
  else no "no argument: the tree line is not the pinned \${1:?usage ...} one (not run: a default could name a real tree)"; fi
}

check_grid(){
  local S="$1"
  usage "$S" 'TREE="${1:?usage: launcher3-grid.sh <graphene-tree-root>}"' "usage: launcher3-grid.sh <graphene-tree-root>"
  mkdir -p "$W/g0"; rc=$(run "$S" g0)
  if [ "$rc" = 1 ] && said g0 "no device_profiles.xml"; then ok "missing device_profiles.xml: exit 1"; else no "missing device_profiles.xml: exit $rc"; fi
  tree_grid g1 pristine; rc=$(run "$S" g1); local f="$W/g1/$DP"
  if [ "$rc" = 0 ] && said g1 "[launcher3-grid] forced 5x5"; then ok "pristine: exit 0, success line"; else no "pristine: exit $rc, or no success line"; fi
  local b; b="$(pblock "$f")"
  if [[ "$b" == *'launcher:canBeDefault="false"'* && "$b" != *'launcher:canBeDefault="true"'* ]]; then ok "pristine: the Pixel 2021 block is canBeDefault=\"false\""; else no "pristine: the Pixel 2021 block is not canBeDefault=\"false\" alone"; fi
  if lacks "$f" 'launcher:iconImageSize="56"' && has "$f" 'launcher:iconImageSize="54"'; then ok "pristine: iconImageSize 56 -> 54"; else no "pristine: iconImageSize not 56 -> 54"; fi
  b="$(lblock "$f")"
  if [[ "$b" == *'launcher:canBeDefault="true"'* ]]; then ok "pristine: the Large Phone block keeps canBeDefault=\"true\" (sed scope)"; else no "pristine: the sed reached the Large Phone block"; fi
  cp "$f" "$W/g1.before"; rc=$(run "$S" g1)
  if [ "$rc" = 0 ] && same "$f" "$W/g1.before"; then ok "re-run: exit 0, file unchanged"; else no "re-run: exit $rc, or the file changed"; fi
  tree_grid g2 renamed; rc=$(run "$S" g2)
  if [ "$rc" = 2 ] && said g2 "[launcher3-grid] DRIFT:"; then ok "Pixel 2021 renamed: exit 2, DRIFT"; else no "Pixel 2021 renamed: exit $rc, or no DRIFT line"; fi
  tree_grid g4 quoted; rc=$(run "$S" g4)
  if [ "$rc" = 2 ] && said g4 "[launcher3-grid] DRIFT:"; then ok "Pixel 2021's canBeDefault the sed cannot match: exit 2, DRIFT"; else no "Pixel 2021's canBeDefault the sed cannot match: exit $rc, or no DRIFT line"; fi
  tree_grid g3 icon58; rc=$(run "$S" g3)
  if [ "$rc" = 2 ] && said g3 "[launcher3-grid] DRIFT:"; then ok "iconImageSize moved to 58: exit 2, DRIFT"; else no "iconImageSize moved to 58: exit $rc, or no DRIFT line"; fi
  # NWP-20261104-26: the GrapheneOS 2026110100 shape.
  local L="packages/apps/Launcher3"
  tree_stock s1 pristine; rc=$(run "$S" s1); f="$W/s1/$DP"
  if [ "$rc" = 0 ] && said s1 "[launcher3-grid] forced 5x5"; then ok "2026110100 shape: exit 0, success line"; else no "2026110100 shape: exit $rc, or no success line"; fi
  if [ ! -e "$W/s1/$L/res-stock/xml/device_profiles.xml" ]; then ok "2026110100 shape: res-stock's grid list removed"; else no "2026110100 shape: res-stock's grid list still there"; fi
  if [ -e "$W/s1/$L/go/quickstep/res/xml/device_profiles.xml" ]; then ok "2026110100 shape: the Launcher3Go list left alone"; else no "2026110100 shape: the Launcher3Go list was removed"; fi
  if lacks "$f" 'launcher:iconImageSize="56"' && has "$f" 'launcher:iconImageSize="54"'; then ok "2026110100 shape: iconImageSize 56 -> 54"; else no "2026110100 shape: iconImageSize not 56 -> 54"; fi
  cp "$f" "$W/s1.before"; rc=$(run "$S" s1)
  if [ "$rc" = 0 ] && same "$f" "$W/s1.before"; then ok "2026110100 shape, re-run: exit 0, file unchanged"; else no "2026110100 shape, re-run: exit $rc, or the file changed"; fi
  for v in grid4x5 nodefault otherlist; do
    tree_stock "s-$v" "$v"; rc=$(run "$S" "s-$v")
    if [ "$rc" = 2 ] && said "s-$v" "[launcher3-grid] DRIFT:"; then ok "2026110100 shape, $v: exit 2, DRIFT"; else no "2026110100 shape, $v: exit $rc, or no DRIFT line"; fi
  done
}

check_qsb(){
  local S="$1"
  local OLD='QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-false}'
  local NEW='QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-true}'
  usage "$S" 'TREE="${1:?usage: launcher3-qsb-firstscreen.sh <graphene-tree-root>}"' "usage: launcher3-qsb-firstscreen.sh <graphene-tree-root>"
  mkdir -p "$W/q0"; rc=$(run "$S" q0)
  if [ "$rc" = 1 ] && said q0 "no buildconfig.sh"; then ok "missing buildconfig.sh: exit 1"; else no "missing buildconfig.sh: exit $rc"; fi
  tree_qsb q1 pristine; rc=$(run "$S" q1); local f="$W/q1/$BC"
  if [ "$rc" = 0 ] && said q1 "[launcher3-qsb] flipped" && has "$f" "$NEW" && lacks "$f" "$OLD"; then ok "pristine: exit 0, flipped, the default is :-true}"; else no "pristine: exit $rc, or the default is not :-true}"; fi
  if has "$f" 'WIDGET_ON_FIRST_SCREEN = ${overrides[WIDGET_ON_FIRST_SCREEN]:-false}'; then ok "pristine: the neighbouring line untouched"; else no "pristine: the neighbouring line changed"; fi
  cp "$f" "$W/q1.before"; rc=$(run "$S" q1)
  if [ "$rc" = 0 ] && said q1 "already applied" && same "$f" "$W/q1.before"; then ok "re-run: exit 0, already applied, file unchanged"; else no "re-run: exit $rc, or not 'already applied', or the file changed"; fi
  tree_qsb q2 quoted; cp "$W/q2/$BC" "$W/q2.before"; rc=$(run "$S" q2)
  if [ "$rc" = 2 ] && said q2 "[launcher3-qsb] DRIFT:" && said q2 ':-"false"}' && same "$W/q2/$BC" "$W/q2.before"; then ok "default line in another form: exit 2, DRIFT quoting the line found, file unchanged"; else no "default line in another form: exit $rc, or no DRIFT line quoting it, or the file changed"; fi
  tree_qsb q3 missing; rc=$(run "$S" q3)
  if [ "$rc" = 2 ] && said q3 "[launcher3-qsb] DRIFT:" && said q3 "<no QSB_ON_FIRST_SCREEN line>"; then ok "no default line: exit 2, DRIFT"; else no "no default line: exit $rc, or no DRIFT line"; fi
}

check_rec(){
  local S="$1"
  usage "$S" 'TREE="${1:?usage: recovery-rebrand.sh <graphene-tree-root>}"' "usage: recovery-rebrand.sh <graphene-tree-root>"
  mkdir -p "$W/r0"; rc=$(run "$S" r0)
  if [ "$rc" = 1 ] && said r0 "no bootable/recovery"; then ok "missing recovery.cpp: exit 1"; else no "missing recovery.cpp: exit $rc"; fi
  tree_rec r1 no-fastboot; rc=$(run "$S" r1)
  if [ "$rc" = 2 ] && said r1 "[recovery-rebrand] DRIFT: no fastboot/fastboot.cpp"; then ok "missing fastboot/fastboot.cpp: exit 2, DRIFT"; else no "missing fastboot/fastboot.cpp: exit $rc, or no DRIFT line"; fi
  tree_rec r2 pristine; rc=$(run "$S" r2)
  if [ "$rc" = 0 ] && said r2 "[recovery-rebrand] recovery/fastbootd titles -> endospore"; then ok "pristine: exit 0, success line"; else no "pristine: exit $rc, or no success line"; fi
  if has "$W/r2/$RC" '"endospore Recovery"' && has "$W/r2/$FB" '"endospore Fastboot"' \
     && lacks "$W/r2/$RC" '"GrapheneOS Recovery"' && lacks "$W/r2/$FB" '"GrapheneOS Fastboot"'; then ok "pristine: both titles rebranded, no GrapheneOS title left"; else no "pristine: a title not rebranded"; fi
  cp "$W/r2/$RC" "$W/r2.rc"; cp "$W/r2/$FB" "$W/r2.fb"; rc=$(run "$S" r2)
  if [ "$rc" = 0 ] && same "$W/r2/$RC" "$W/r2.rc" && same "$W/r2/$FB" "$W/r2.fb"; then ok "re-run: exit 0, files unchanged"; else no "re-run: exit $rc, or a file changed"; fi
  tree_rec r3 fastboot-drift; rc=$(run "$S" r3)
  if [ "$rc" = 2 ] && said r3 "[recovery-rebrand] DRIFT:"; then ok "fastboot title literal moved: exit 2, DRIFT"; else no "fastboot title literal moved: exit $rc, or no DRIFT line"; fi
  tree_rec r4 recovery-drift; rc=$(run "$S" r4)
  if [ "$rc" = 2 ] && said r4 "[recovery-rebrand] DRIFT:"; then ok "recovery title literal moved: exit 2, DRIFT"; else no "recovery title literal moved: exit $rc, or no DRIFT line"; fi
}

check_brand(){
  local S="$1"
  usage "$S" 'TREE="${1:?usage: endospore-brand-strings.sh <graphene-tree-root>}"' "usage: endospore-brand-strings.sh <graphene-tree-root>"
  mkdir -p "$W/b0"; rc=$(run "$S" b0)
  if [ "$rc" = 1 ] && said b0 "no framework-res strings"; then ok "missing framework-res strings: exit 1"; else no "missing framework-res strings: exit $rc"; fi
  tree_brand b1 pristine; rc=$(run "$S" b1)
  if [ "$rc" = 0 ] && said b1 "[brand-strings] done"; then ok "pristine: exit 0, success line"; else no "pristine: exit $rc, or no success line"; fi
  if has "$W/b1/$FRW" '<string name="android_system_label">endospore</string>' && has "$W/b1/$FRW" 'endospore plans to phase out' \
     && has "$W/b1/$SEX" 'endospore will remain installed' && has "$W/b1/$FRWMAN" 'android:label="endospore"' \
     && same "$W/b1/$ICON" "$NOWHERE_SPORE_SRC"; then ok "pristine: all five targets reached"; else no "pristine: a target not reached"; fi
  if has "$W/b1/$SEX" 'GrapheneOS proxy'; then ok "pristine: the infrastructure string left alone"; else no "pristine: the infrastructure string was rebranded"; fi
  cp "$W/b1/$FRW" "$W/b1.frw"; cp "$W/b1/$SEX" "$W/b1.sex"; rc=$(run "$S" b1)
  if [ "$rc" = 0 ] && same "$W/b1/$FRW" "$W/b1.frw" && same "$W/b1/$SEX" "$W/b1.sex"; then ok "re-run: exit 0, files unchanged"; else no "re-run: exit $rc, or a file changed"; fi
  local n=1 d
  for d in label abi duress applabel; do
    n=$((n+1)); tree_brand b$n $d; rc=$(run "$S" b$n)
    if [ "$rc" = 2 ] && said b$n "[brand-strings] DRIFT:"; then ok "$d anchor moved: exit 2, DRIFT"; else no "$d anchor moved: exit $rc, or no DRIFT line"; fi
  done
  rc=$(NOWHERE_SPORE_SRC="$W/no-such-icon.xml" run "$S" b1)
  if [ "$rc" = 2 ] && said b1 "[brand-strings] DRIFT:"; then ok "icon present but its source gone: exit 2, DRIFT (not 'already the spore')"; else no "icon present but its source gone: exit $rc, or no DRIFT line"; fi
  tree_brand b9 pristine; rc=$(NOWHERE_SPORE_SRC="$W/no-such-icon.xml" run "$S" b9)
  if [ "$rc" = 2 ] && said b9 "[brand-strings] DRIFT: spore source not found"; then ok "spore source missing: exit 2, DRIFT"; else no "spore source missing: exit $rc, or no DRIFT line"; fi
}

check_attest(){
  local S="$1"
  usage "$S" 'TREE="${1:?usage: endospore-attest-strings.sh <graphene-tree-root>}"' "usage: endospore-attest-strings.sh <graphene-tree-root>"
  mkdir -p "$W/a0"; rc=$(run "$S" a0)
  if [ "$rc" = 1 ] && said a0 "no strings file"; then ok "missing strings file: exit 1"; else no "missing strings file: exit $rc"; fi
  tree_attest a1 pristine; rc=$(run "$S" a1)
  if [ "$rc" = 0 ] && said a1 "[attest-strings] done" && has "$W/a1/$SEX" 'endospore server' && has "$W/a1/$AEP" 'endospore exploit protection' \
     && lacks "$W/a1/$SEX" GrapheneOS && lacks "$W/a1/$AEP" GrapheneOS; then ok "pristine: exit 0, both files neutralized"; else no "pristine: exit $rc, or a file not neutralized"; fi
  cp "$W/a1/$SEX" "$W/a1.sex"; rc=$(run "$S" a1)
  if [ "$rc" = 0 ] && said a1 "nothing to change" && same "$W/a1/$SEX" "$W/a1.sex"; then ok "re-run: exit 0, nothing to change, file unchanged"; else no "re-run: exit $rc, or not 'nothing to change', or the file changed"; fi
  tree_attest a2 clean; rc=$(run "$S" a2)
  if [ "$rc" = 0 ] && said a2 "already neutralized"; then ok "already neutralized tree: exit 0"; else no "already neutralized tree: exit $rc"; fi
  tree_attest a3 reworded; rc=$(run "$S" a3)
  if [ "$rc" = 2 ] && said a3 "[attest-strings] DRIFT:"; then ok "strings reworded upstream: exit 2, DRIFT"; else no "strings reworded upstream: exit $rc, or no DRIFT line"; fi
}

for S in "${SUTS[@]}"; do
  [ -f "$S" ] || { no "no such file: $S"; continue; }
  S="$(cd "$(dirname "$S")" && pwd)/$(basename "$S")"   # absolute: the usage check runs it from an empty dir
  echo "== ${S#"$ED"/} =="
  case "$(kind "$S")" in
    grid) check_grid "$S" ;;
    qsb)  check_qsb "$S" ;;
    rec)  check_rec "$S" ;;
    brand)  check_brand "$S" ;;
    attest) check_attest "$S" ;;
    *)    no "unknown patch kind: $(basename "$S")" ;;
  esac
  rm -rf "${W:?}"/*
done

# One patch replicated five times: a fix that lands in four copies and not the fifth must fail here.
if [ "$DEFAULT_LIST" = yes ]; then
  echo "== the five device copies match below their header line =="
  for f in launcher3-grid.sh launcher3-qsb-firstscreen.sh; do
    bad=""
    for d in $DEVICES; do
      tail -n +3 "$ED/devices/$d/patches/$f" > "$W/copy"
      tail -n +3 "$ED/devices/lynx/patches/$f" > "$W/lynx"
      same "$W/copy" "$W/lynx" || bad="$bad $d"
    done
    if [ -z "$bad" ]; then ok "$f: all five copies identical from line 3"; else no "$f: differs from lynx's in:$bad"; fi
  done
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M="$W/mut"; mkdir -p "$M"; i=0
  mutate(){   # <sut> <label> <sed>
    i=$((i+1)); mkdir -p "$M/$i"; local m; m="$M/$i/$(basename "$1")"
    if ! sed "$3" "$1" > "$m" 2>"$M/err"; then no "MUTATION BROKEN (sed): $2"; return; fi
    if cmp -s "$1" "$m"; then no "MUTATION INERT: $2"; return; fi
    if bash "$0" "$m" >/dev/null 2>&1; then no "NOT CONVICTED: $2 -- suite passes on broken code"
    else ok "convicted: $2"; fi
  }
  for S in "${SUTS[@]}"; do
    [ -f "$S" ] || continue
    S="$(cd "$(dirname "$S")" && pwd)/$(basename "$S")"
    t="${S#"$ED"/}"
    case "$(kind "$S")" in
      grid)
        mutate "$S" "$t: canBeDefault=false assert removed"  '/# assert:grid-cbd-false$/d'
        mutate "$S" "$t: iconImageSize=54 assert removed"    '/# assert:grid-icon-54$/d'
        mutate "$S" "$t: every assertion removed"            '/# assert:/d'
        mutate "$S" "$t: sole-list assert removed"           '/# assert:grid-sole-list$/d'
        mutate "$S" "$t: 5x5-default assert removed"         '/# assert:grid-5x5-default$/d'
        mutate "$S" "$t: no-4x5 assert removed"              '/# assert:grid-no-4x5$/d'
        mutate "$S" "$t: res-stock's list not removed"       's|^rm -f "\$L3/res-stock/xml/device_profiles.xml"$|: rm -f|'
        mutate "$S" "$t: the sed writes 55, not 54"          's|/launcher:iconImageSize="54"/g|/launcher:iconImageSize="55"/g|'
        mutate "$S" "$t: the canBeDefault sed unscoped"      's|^sed -i '"'"'/launcher:name="Pixel 2021"/,/\\/>/ s/|sed -i '"'"'s/|' ;;
      qsb)
        mutate "$S" "$t: drift exits 0"                      '/# assert:qsb-drift$/ s/exit 2/exit 0/'
        mutate "$S" "$t: every assertion removed"            '/# assert:/d'
        mutate "$S" "$t: the sed writes :-tru}"              's|QSB_ON_FIRST_SCREEN\]:-true}/'"'"' "\$BC"|QSB_ON_FIRST_SCREEN]:-tru}/'"'"' "$BC"|'
        mutate "$S" "$t: already-applied branch removed"     's|^elif grep -cF -- "\$NEW" "\$BC" >/dev/null; then$|elif false; then|' ;;
      rec)
        mutate "$S" "$t: endospore Recovery assert removed"  '/# assert:rec-endospore-recovery$/d'
        mutate "$S" "$t: endospore Fastboot assert removed"  '/# assert:rec-endospore-fastboot$/d'
        mutate "$S" "$t: missing fastboot.cpp exits 0"       '/# assert:rec-fastboot-present$/ s/exit 2/exit 0/'
        mutate "$S" "$t: missing fastboot.cpp guard removed" '/# assert:rec-fastboot-present$/d'
        mutate "$S" "$t: every assertion removed"            '/# assert:/d' ;;
      brand)
        mutate "$S" "$t: android_system_label assert removed" '/# assert:brand-system-label$/d'
        mutate "$S" "$t: 32-bit message assert removed"       '/# assert:brand-abi-message$/d'
        mutate "$S" "$t: duress assert removed"               '/# assert:brand-duress$/d'
        mutate "$S" "$t: application label assert removed"    '/# assert:brand-app-label$/d'
        mutate "$S" "$t: icon assert removed"                 '/# assert:brand-icon$/d'
        mutate "$S" "$t: missing spore source exits 0"        '/# assert:brand-spore-src$/ s/exit 2/exit 0/'
        mutate "$S" "$t: every assertion removed"             '/# assert:/d' ;;
      attest)
        mutate "$S" "$t: endospore-present assert removed"    '/# assert:attest-endospore$/d'
        mutate "$S" "$t: drift exits 0"                       's/exit 2; }/exit 0; }/'
        mutate "$S" "$t: every assertion removed"             '/# assert:/d' ;;
    esac
  done
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
