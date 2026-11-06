#!/usr/bin/env bash
# test-appcode-arms.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's materializeapp and stageapp arms clean up after a
# failure, and stageapp never leaves a downloaded APK in /data/nowhere (NWP-20261017-27).
#
# WHY THIS IS COMMITTED. Both arms were executed by no test except the package-name guard (test-appcode-pkg-guard.sh).
# What that leaves unpinned is what each arm does AFTER the guard:
#   materializeapp: a failed fetch (agent exit 1, or exit 0 with no dir) must leave NO .appcode/<pkg> and answer
#     ERR-FETCH, while a sibling app's in-flight set is left alone; success chowns the set to the chooser dir's owner and
#     answers `OK <pkg>`.
#   stageapp: /data/nowhere is plain /data, which survives power-off, so the stage /data/nowhere/fetchapp/<pkg> -- a
#     downloaded catalog APK set -- must be removed on EVERY path (success, no APK landed, no stage/chooser dir), or it
#     lingers across sessions (the amnesia rule). With no APK landed the answer is ERR-STAGE and the half-made
#     .appcode/<pkg> is removed too. The agent consumes both replies (app_code.go, catalog.go).
# NWP-20261109-11 (Q116): a sign-out cancels the download. The arm hands the agent NOWHERE_OD_CANCEL="$STATE/od-cancel"
# (the stub records what it saw), and a failed fetch with that marker present answers ERR-CANCELLED (and logs it) where
# the same failure without it stays ERR-FETCH; a set that landed whole is kept, marker or no marker.
# The roamed manifest.tsv is read by nothing at login (StoreInstaller), so nothing is asserted about it on a failure path.
#
# NWP-20261028-14: stageapp answers OK only when EVERY staged APK landed byte-identical. The daemon verified the stage,
# never the copies, and the chooser's installStaged commits whatever *.apk is in .appcode/<pkg> as one session, so
# (k) a split whose cp fails (ENOSPC) must not leave a base without its native libs, and (l) a cp that dies part-way
# (a cut file, exit 0) must not be committed. Both answer ERR-STAGE, leave no .appcode/<pkg> and no manifest line, and
# still remove the stage. A cp stub reaches the arm through run_case's CP_MODE.
#
# pkgname_ok and each arm are extracted BY ANCHOR (a function from `<name>() {` to its first `}` line; an arm from
# `  <op>)` to the arm-closing `    ;;` line), so the extraction works with either guard line. /data/nowhere/fetchapp is
# rewritten to a scratch root and USERDIR points into it; $AGENT is a stub whose behaviour the case picks, and
# stat/chown/restorecon are stubs (chown records its argv). Each case runs under every POSIX shell found (bash, and
# sh/dash/mksh where they are not bash), since the arms are POSIX.
#
#   bash test-appcode-arms.sh            # the cases
#   bash test-appcode-arms.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PKG=org.fossify.math
SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done

extract_arm() { # <script> <op> -> the arm text, or nothing
  awk -v start="  $2)" '
    $0 == start { on = 1 }
    on { print }
    on && $0 == "    ;;" { exit }' "$1"
}
extract_fn() { # <script> <name> -> the function text, or nothing
  awk -v start="$2() {" '
    $0 == start { on = 1 }
    on { print }
    on && $0 == "}" { exit }' "$1"
}

# run_case <shell> <helper> <arm> <op> <agent:ok|fail|empty> <chooser:yes|no> <stage:none|apks|noapk> [<cp:none|splitfail|splitcut> [<marker:yes|no>]]
#   -> key=value lines
run_case() {
  local sh="$1" helper="$2" arm="$3" op="$4" agent="$5" chooser="$6" stage="$7" cpmode="${8:-none}" marker="${9:-no}" root files log
  root=$(mktemp -d -p "$W")
  files="$root/user/12/com.nowhere.chooser/files"
  mkdir -p "$root/nowhere/fetchapp" "$root/user/12"
  if [ "$chooser" = yes ]; then
    mkdir -p "$files/.appcode/other"; : > "$files/.appcode/other/base.apk"
  fi
  case "$stage" in
    apks)  mkdir -p "$root/nowhere/fetchapp/$PKG" "$root/orig"
           printf 'base-apk:%s:0123456789' "$PKG" > "$root/orig/base.apk"
           printf 'split-apk:%s:abcdefghijklmnop' "$PKG" > "$root/orig/split_config.apk"
           command cp "$root/orig/base.apk" "$root/orig/split_config.apk" "$root/nowhere/fetchapp/$PKG/"
           printf '%s\t1\n' "$PKG" > "$root/nowhere/fetchapp/$PKG/manifest.line" ;;
    noapk) mkdir -p "$root/nowhere/fetchapp/$PKG"; printf '%s\t1\n' "$PKG" > "$root/nowhere/fetchapp/$PKG/manifest.line" ;;
  esac
  printf '#!/bin/sh\nprintf "%%s" "$NOWHERE_OD_CANCEL" > "${0%%/*}/agent.env"\ncase "$AGENT_MODE" in\n ok) mkdir -p "$6/$5" && : > "$6/$5/base.apk"; exit 0;;\n empty) exit 0;;\n *) mkdir -p "$6/$5"; : > "$6/$5/partial"; exit 1;;\nesac\n' \
    > "$root/agent"; chmod +x "$root/agent"
  arm=${arm//\/data\/nowhere\/fetchapp/$root/nowhere/fetchapp}
  ROOT="$root" OP="$op" PKGN="$PKG" ARM="$arm" HELPER="$helper" AGENT_MODE="$agent" CP_MODE="$cpmode" MARKER="$marker" "$sh" -c '
    LOG="$ROOT/log"; RES="$ROOT/res"; STATE="$ROOT/state"; mkdir -p "$STATE"
    if [ "$MARKER" = yes ]; then : > "$STATE/od-cancel"; fi
    AGENT="$ROOT/agent"; USERDIR="$ROOT/user/12"; uid=12; name=x; pass=y; srcunit="$PKGN"
    pw() { printf "%s" "$1"; }
    stat() { echo 4242; }; restorecon() { :; }
    chown() { echo "chown $*" >> "$ROOT/chown.log"; }
    case "$CP_MODE" in
      splitfail) cp() { case "$1" in *split_config.apk) return 1 ;; esac; command cp "$@"; } ;;
      splitcut)  cp() { case "$1" in *split_config.apk) _d="$2"; [ -d "$_d" ] && _d="$_d/${1##*/}"; head -c 4 "$1" > "$_d"; return 0 ;; esac; command cp "$@"; } ;;
    esac
    eval "$HELPER"
    eval "case $OP in
$ARM
esac"
    ' >/dev/null 2>&1 </dev/null
  printf 'reply=%s\n' "$(cat "$root/res" 2>/dev/null)"
  [ -e "$files/.appcode/$PKG" ] && echo HAVE-PKG
  [ -e "$files/.appcode/$PKG/base.apk" ] && echo HAVE-BASE
  [ -e "$files/.appcode/$PKG/split_config.apk" ] && echo HAVE-SPLIT
  cmp -s "$root/orig/base.apk" "$files/.appcode/$PKG/base.apk" 2>/dev/null && echo BASE-WHOLE
  cmp -s "$root/orig/split_config.apk" "$files/.appcode/$PKG/split_config.apk" 2>/dev/null && echo SPLIT-WHOLE
  [ -e "$files/.appcode/other/base.apk" ] && echo HAVE-SIBLING
  [ -e "$root/nowhere/fetchapp/$PKG" ] && echo HAVE-STAGE
  [ -e "$root/user/12/com.nowhere.chooser" ] && echo HAVE-CHOOSER
  [ -e "$files/.appcode" ] && [ "$chooser" = no ] && echo MADE-APPCODE
  log=$(grep -o 'materializeapp [^ ]* CANCELLED for a sign-out' "$root/log" 2>/dev/null)
  [ -n "$log" ] && printf 'cancellog=%s\n' "$log"
  [ -f "$root/agent.env" ] && printf 'odenv=%s\n' "$(sed "s#$root#ROOT#g" "$root/agent.env")"
  log=$(grep -o 'stageapp [^ ]* FAILED ([^)]*)' "$root/log" 2>/dev/null)
  [ -n "$log" ] && printf 'log=%s\n' "$log"
  [ -f "$files/.appcode/manifest.tsv" ] && printf 'manifest=%s\n' "$(tr '\t\n' '  ' < "$files/.appcode/manifest.tsv")"
  [ -f "$root/chown.log" ] && sed "s#$root#ROOT#g" "$root/chown.log" | sed 's/^/chown: /'
  command rm -rf "$root"
  return 0
}

suite() {
  local f="$1" quiet="${2:-}" only="${3:-}" p=0 x=0 helper marm sarm sh out tag
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
  # expect <label> <present...> -- <absent...>
  expect() {
    local label="$1" w bad="" present=1; shift
    for w in "$@"; do
      if [ "$w" = -- ]; then present=0; continue; fi
      if [ "$present" = 1 ]; then has "$w" || bad="$bad missing[$w]"; else has "$w" && bad="$bad unwanted[$w]"; fi
    done
    if [ -z "$bad" ]; then ok "$tag $label"; else no "$tag $label:$bad  got: $(tr '\n' ' ' <<<"$out")"; fi
  }
  helper=$(extract_fn "$f" pkgname_ok)
  case "$helper" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED -- pkgname_ok moved in $f" >&2; return 2 ;; esac
  marm=$(extract_arm "$f" materializeapp)
  case "$marm" in *'restore-app'*'ERR-FETCH'*) ;; *) echo "EXTRACTION FAILED -- the materializeapp arm moved in $f" >&2; return 2 ;; esac
  sarm=$(extract_arm "$f" stageapp)
  case "$sarm" in *'fetchapp'*'ERR-STAGE'*) ;; *) echo "EXTRACTION FAILED -- the stageapp arm moved in $f" >&2; return 2 ;; esac
  for sh in "${SHELLS[@]}"; do
    [ -z "$only" ] || [ "$sh" = "$only" ] || continue
    tag="[${sh##*/}]"
    out=$(run_case "$sh" "$helper" "$marm" materializeapp ok yes none)
    expect "materializeapp (a) fetched -> OK, set present, sibling kept" "reply=OK $PKG" HAVE-BASE HAVE-SIBLING
    expect "materializeapp (a) chowns the set to the chooser dir's owner" "chown: chown -R 4242:4242 ROOT/user/12/com.nowhere.chooser/files/.appcode"
    out=$(run_case "$sh" "$helper" "$marm" materializeapp fail yes none)
    expect "materializeapp (b) agent exit 1 -> ERR-FETCH, no set, (d) sibling kept" "reply=ERR-FETCH" HAVE-SIBLING -- HAVE-PKG HAVE-BASE
    out=$(run_case "$sh" "$helper" "$marm" materializeapp empty yes none)
    expect "materializeapp (c) agent exit 0 but no dir -> ERR-FETCH, no set, (d) sibling kept" "reply=ERR-FETCH" HAVE-SIBLING -- HAVE-PKG
    out=$(run_case "$sh" "$helper" "$marm" materializeapp fail yes none none yes)
    expect "materializeapp (A1) agent exit 1 with the sign-out marker -> ERR-CANCELLED, no set, logged, sibling kept" \
      "reply=ERR-CANCELLED" "cancellog=materializeapp $PKG CANCELLED for a sign-out" HAVE-SIBLING -- HAVE-PKG HAVE-BASE reply=ERR-FETCH
    out=$(run_case "$sh" "$helper" "$marm" materializeapp fail yes none none no)
    expect "materializeapp (A2) agent exit 1 without the marker -> ERR-FETCH, not cancelled" "reply=ERR-FETCH" -- ERR-CANCELLED cancellog=
    out=$(run_case "$sh" "$helper" "$marm" materializeapp ok yes none none yes)
    expect "materializeapp (A3) a set that landed whole with the marker present is kept -> OK" "reply=OK $PKG" HAVE-BASE -- ERR-CANCELLED cancellog=
    out=$(run_case "$sh" "$helper" "$marm" materializeapp ok yes none none no)
    expect "materializeapp (A4) the agent sees NOWHERE_OD_CANCEL=\$STATE/od-cancel" "odenv=ROOT/state/od-cancel"
    out=$(run_case "$sh" "$helper" "$marm" materializeapp ok no none)
    expect "materializeapp (e) no chooser dir -> ERR-FETCH, nothing created" "reply=ERR-FETCH" -- HAVE-CHOOSER HAVE-PKG MADE-APPCODE

    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail yes apks)
    expect "stageapp (f) two APKs -> OK, both copied, manifest line appended, stage GONE, (j) sibling kept" \
      "reply=OK $PKG" HAVE-BASE HAVE-SPLIT HAVE-SIBLING "manifest=$PKG 1" -- HAVE-STAGE
    expect "stageapp (m) both copies byte-identical to the stage content" BASE-WHOLE SPLIT-WHOLE
    expect "stageapp (f) chowns the set to the chooser dir's owner" "chown: chown -R 4242:4242 ROOT/user/12/com.nowhere.chooser/files/.appcode"
    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail yes noapk)
    expect "stageapp (g) no *.apk -> ERR-STAGE, no set, stage GONE, (j) sibling kept" "reply=ERR-STAGE" HAVE-SIBLING "log=stageapp $PKG FAILED (0 of 0 apk copied whole)" -- HAVE-PKG HAVE-STAGE
    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail yes apks splitfail)
    expect "stageapp (k) split cp fails -> ERR-STAGE, no set, no manifest line, stage GONE, sibling kept" \
      "reply=ERR-STAGE" HAVE-SIBLING "log=stageapp $PKG FAILED (1 of 2 apk copied whole)" -- HAVE-PKG HAVE-BASE HAVE-SPLIT HAVE-STAGE manifest=
    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail yes apks splitcut)
    expect "stageapp (l) split copied cut (cp exit 0) -> ERR-STAGE, no set, no manifest line, stage GONE" \
      "reply=ERR-STAGE" HAVE-SIBLING "log=stageapp $PKG FAILED (1 of 2 apk copied whole)" -- HAVE-PKG HAVE-BASE HAVE-SPLIT HAVE-STAGE manifest=
    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail no apks)
    expect "stageapp (h) no chooser dir -> ERR-STAGE, stage GONE" "reply=ERR-STAGE" -- HAVE-STAGE HAVE-PKG HAVE-CHOOSER
    out=$(run_case "$sh" "$helper" "$sarm" stageapp fail yes none)
    expect "stageapp (i) no stage dir -> ERR-STAGE, no set, (j) sibling kept" "reply=ERR-STAGE" HAVE-SIBLING -- HAVE-PKG HAVE-STAGE
  done
  [ -n "$quiet" ] || printf 'shells: %s\n%d passed, %d failed\n' "${SHELLS[*]}" "$p" "$x"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" || { echo "baseline suite fails; fix it before mutating" >&2; exit 1; }
echo "-- mutations (each must be CONVICTED) --"
fail=0; tmp=$(mktemp -d -p "$W")
convict() { # <label> <mutant script>
  if cmp -s "$2" "$SUT"; then echo "  MUTANT FAILED TO APPLY: $1" >&2; fail=1; return; fi
  # every shell must convict on its own: a mutant that one shell still passes SURVIVED there
  local s
  for s in "${SHELLS[@]}"; do
    if suite "$2" quiet "$s" >/dev/null 2>&1; then echo "  SURVIVED  $1 [${s##*/}]"; fail=1; else echo "  convicted $1 [${s##*/}]"; fi
  done
}
# mut_arm <label> <op> <from> <to>: replace the first literal <from> inside the <op> arm with <to>
mut_arm() {
  local m="$tmp/m.sh"
  awk -v start="  $2)" -v from="$3" -v to="$4" '
    $0 == start { on = 1 }
    on && !done && index($0, from) {
      done = 1
      i = index($0, from); $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
    }
    on && $0 == "    ;;" { on = 0 }
    { print }' "$SUT" > "$m"
  convict "$1" "$m"
}
mut_arm "materializeapp: failure branch keeps the half-made set" materializeapp '      rm -rf "$APPCODE/$pkg"' '      :'
mut_arm "materializeapp: success no longer requires the dir"      materializeapp '&& [ -d "$APPCODE/$pkg" ]; then' '&& true; then'
mut_arm "materializeapp A5: the sign-out marker test removed"     materializeapp '[ -e "$STATE/od-cancel" ]' 'false'
mut_arm "materializeapp A6: the agent is not told the marker path" materializeapp ' NOWHERE_OD_CANCEL="$STATE/od-cancel"' ''
mut_arm "materializeapp A7: the marker is checked on the success path" materializeapp 'echo "OK $pkg" > "$RES"' 'if [ -e "$STATE/od-cancel" ]; then echo "ERR-CANCELLED" > "$RES"; else echo "OK $pkg" > "$RES"; fi'
mut_arm "stageapp: success path leaves the stage"                 stageapp '      rm -rf "$STAGE"  ' '      :  '
mut_arm "stageapp: no stage/chooser dir leaves the stage"         stageapp 'rm -rf "$STAGE" 2>/dev/null' ':'
mut_arm "stageapp: no apk landed keeps the half-made set (g)"     stageapp 'rm -rf "$APPCODE/$pkg"; echo "[roamd] stageapp $pkg FAILED ($n of' 'echo "[roamd] stageapp $pkg FAILED ($n of'
mut_arm "stageapp S1: OK on any copied apk, not all of them"      stageapp '[ "$n" -eq "$want" ]' 'true'
mut_arm "stageapp S2: the copy is no longer compared to the stage" stageapp ' && cmp -s "$_a" "$_d"' ''
mut_arm "stageapp S3: manifest line appended before the verdict"  stageapp '[ "$whole" = yes ] && [ -f "$STAGE/manifest.line" ]' '[ -f "$STAGE/manifest.line" ]'
mut_arm "stageapp S4: a shortfall keeps the half-made set (k)"    stageapp 'rm -rf "$APPCODE/$pkg"; echo "[roamd] stageapp $pkg FAILED ($n of' 'echo "[roamd] stageapp $pkg FAILED ($n of'
mut_arm "stageapp: pre-copy clear widened to all of .appcode"     stageapp 'rm -rf "$APPCODE/$pkg"       ' 'rm -rf "$APPCODE"            '
command rm -rf "$tmp"
[ "$fail" = 0 ] && echo "all mutants convicted" || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
