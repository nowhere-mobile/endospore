#!/usr/bin/env bash
# test-rc-services.sh [--mutate] [--rc=<nowhere.rc>] [--bp=<Android.bp>] [--roamd=<nowhere_roamd.sh>] -- the
# per-service lines of core/vendor-common/etc/nowhere.rc that its own comments state as contracts.
#
# WHY THIS IS COMMITTED (NWP-20261116-23). Nothing checked these lines. The read-only and credential lanes have no
# `inet` group, so a network attempt on them fails loudly (the rc calls this the lane's second guard). nowhere_mediad
# is `oneshot` so that a crash cannot restart-loop against an already-consumed mediad.req. nowhere_login is the one
# long-running service and the one with a socket, and the chooser reaches it through that socket's mode and label.
# The ro and cred lanes select their arm of nowhere_roamd.sh's `case "$LANE" in` by argument, and any other argument
# silently runs a second RW lane (`*) LANE=rw`). And init can only exec a service script that an Android.bp
# sh_binary installs: without it `ctl.start` silently does nothing. Each of these could regress with CI green.
#
# NOT pinned here, because other suites already hold them:
#   editions/endospore/build/test-rc-retarget.sh   each service's seclabel and the service set ((b)), `disabled` on
#                                                  every service and the boot_completed order ((m)-(o));
#   editions/test-core-module-parity.sh            every nowhere* module of core/vendor-common/Android.bp in BOTH
#                                                  editions' PRODUCT_PACKAGES. It enumerates FROM Android.bp, so it
#                                                  cannot see an rc service whose sh_binary was removed: (f) here does.
#
# BASH ONLY. The suite reads three files as data with awk and runs no device code, so the every-shell rule for suites
# that execute daemon script code (bash, sh, dash, mksh) does not apply.
#
# Exit 0 = every check passes; 1 = a FAIL line; 2 = a harness failure (a missing input, an rc parse that does not find
# exactly the eight services, a missing `case "$LANE" in` anchor, an unknown argument).
#
#   bash core/vendor-common/bin/test-rc-services.sh            # the checks against the repo's files
#   bash core/vendor-common/bin/test-rc-services.sh --mutate   # ... plus broken copies that must each CONVICT the suite
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
SELF="$HERE/$(basename "$0")"
MUTATE=no
RC_SRC="$ROOT/core/vendor-common/etc/nowhere.rc"
BP_SRC="$ROOT/core/vendor-common/Android.bp"
ROAMD_SRC="$ROOT/core/vendor-common/bin/nowhere_roamd.sh"
for a in "$@"; do
  case "$a" in
    --mutate)  MUTATE=yes ;;
    --rc=*)    RC_SRC="${a#--rc=}" ;;
    --bp=*)    BP_SRC="${a#--bp=}" ;;
    --roamd=*) ROAMD_SRC="${a#--roamd=}" ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
for f in "$RC_SRC" "$BP_SRC" "$ROAMD_SRC"; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }

SERVICES="nowhere_login nowhere_provision nowhere_roamd nowhere_roamd_ro nowhere_roamd_cred nowhere_otad nowhere_mediad nowhere_gate"
LOGIN_SOCKET='socket nowhere_login stream 0666 root root u:object_r:nowhere_login_socket:s0'

# The rc parse: a service block runs from its `service` line to the next line that is not indented (a column-0
# comment, a blank line, an `on` line or another `service`). One record per line:
#   svc <name>
#   exec <name> <path> [args...]            the service line after the name, fields joined by one space
#   body <name> <line>                      an indented line, leading whitespace stripped, otherwise byte-exact
# An indented comment inside a block is skipped.
RECS=$(mktemp -p "$W")
awk '
  /^service[ \t]/ {
    svc = $2; print "svc " svc
    ex = ""; for (i = 3; i <= NF; i++) ex = ex (i > 3 ? " " : "") $i
    print "exec " svc " " ex; next
  }
  /^[ \t]/ && svc != "" {
    line = $0; sub(/^[ \t]+/, "", line)
    if (line == "" || substr(line, 1, 1) == "#") next
    print "body " svc " " line; next
  }
  { svc = "" }
' "$RC_SRC" > "$RECS"

# svclines <name> -> that service's body lines, one per line
svclines(){ awk -v s="$1" '$1 == "body" && $2 == s { print substr($0, length("body " s " ") + 1) }' "$RECS"; }
# svcexec <name> -> the service line's path and arguments
svcexec(){ awk -v s="$1" '$1 == "exec" && $2 == s { print substr($0, length("exec " s " ") + 1) }' "$RECS"; }
# count <exact line> <text> -> how many lines of <text> equal <exact line>
count(){ awk -v want="$1" '$0 == want { n++ } END { print n + 0 }' <<<"$2"; }

echo "== (a) the rc parse finds exactly the eight services =="
GOT=$(awk '$1 == "svc" { print $2 }' "$RECS" | sort | tr '\n' ' ')
WANT=$(printf '%s\n' $SERVICES | sort | tr '\n' ' ')
if [ "$GOT" != "$WANT" ]; then
  echo "HARNESS: the rc parse of $RC_SRC found [$GOT], want the eight services [$WANT]" >&2
  exit 2
fi
ok "(a) the rc parse found the eight services, each once"

echo "== (b) the login daemon: long-running, the one socket =="
L=$(svclines nowhere_login)
[ "$(count oneshot "$L")" -eq 0 ] && ok "(b) nowhere_login is not oneshot" || no "(b) nowhere_login is oneshot (init would not restart the login daemon)"
SOCKS=$(awk '/^socket[ \t]/' <<<"$L")
NS=$(awk 'END { print NR }' <<<"$SOCKS"); [ -z "$SOCKS" ] && NS=0
if [ "$NS" -eq 1 ] && [ "$SOCKS" = "$LOGIN_SOCKET" ]; then
  ok "(b) nowhere_login has exactly the one socket line, byte for byte"
else
  no "(b) nowhere_login socket lines: got $NS [$SOCKS] want 1 [$LOGIN_SOCKET]"
fi
for s in $SERVICES; do
  [ "$s" = nowhere_login ] && continue
  SOCKS=$(svclines "$s" | awk '/^socket[ \t]/')
  [ -z "$SOCKS" ] && ok "(b) $s has no socket line" || no "(b) $s has a socket line: [$SOCKS]"
done

echo "== (c) oneshot on every worker, user root on every service =="
for s in $SERVICES; do
  B=$(svclines "$s")
  if [ "$s" != nowhere_login ]; then
    [ "$(count oneshot "$B")" -ge 1 ] && ok "(c) $s is oneshot" || no "(c) $s is not oneshot (init would restart it after a crash)"
  fi
  [ "$(count 'user root' "$B")" -ge 1 ] && ok "(c) $s runs as user root" || no "(c) $s has no 'user root' line"
done

echo "== (d) inet only where a service talks to the network =="
for s in $SERVICES; do
  case " nowhere_login nowhere_roamd nowhere_otad nowhere_mediad " in *" $s "*) want=yes ;; *) want=no ;; esac
  G=$(svclines "$s" | awk '/^group[ \t]/')
  if [ -z "$G" ]; then no "(d) $s has no group line"; continue; fi
  HAS=$(awk '{ for (i = 2; i <= NF; i++) if ($i == "inet") f = 1 } END { print (f ? "yes" : "no") }' <<<"$G")
  if [ "$HAS" = "$want" ]; then
    [ "$want" = yes ] && ok "(d) $s has inet" || ok "(d) $s has no inet"
  else
    [ "$want" = yes ] && no "(d) $s lost inet: [$G]" || no "(d) $s gained inet: [$G]"
  fi
done

echo "== (e) the lane arguments and roamd's lane arms =="
is_exec(){
  local s="$1" want="$2" got; got=$(svcexec "$s")
  [ "$got" = "$want" ] && ok "(e) $s runs [$want]" || no "(e) $s runs [$got], want [$want]"
}
is_exec nowhere_roamd      "/system/bin/nowhere_roamd.sh"
is_exec nowhere_roamd_ro   "/system/bin/nowhere_roamd.sh ro"
is_exec nowhere_roamd_cred "/system/bin/nowhere_roamd.sh cred"
CASE=$(awk '!on && $0 == "case \"$LANE\" in" { on = 1 } on { print } on && $0 == "esac" { exit }' "$ROAMD_SRC")
case "$CASE" in
  'case "$LANE" in'*esac) ;;
  *) echo "HARNESS: no 'case \"\$LANE\" in' ... 'esac' block in $ROAMD_SRC" >&2; exit 2 ;;
esac
for arm in ro cred; do
  N=$(awk -v a="$arm" '{ l = $0; sub(/^[ \t]+/, "", l); if (index(l, a ")") == 1) n++ } END { print n + 0 }' <<<"$CASE")
  [ "$N" -ge 1 ] && ok "(e) nowhere_roamd.sh's case \"\$LANE\" has a $arm) arm" || no "(e) nowhere_roamd.sh's case \"\$LANE\" has no $arm) arm (the $arm lane would run as RW)"
done

echo "== (f) an Android.bp module installs each service script and the rc =="
# One record per top-level module: "<type> <first name> <first src>" (src empty when the module has none).
MODS=$(awk '
  /^[A-Za-z_]+[ \t]*\{[ \t]*$/ { t = $1; sub(/\{$/, "", t); name = ""; src = ""; inm = 1; next }
  inm && /^\}/ { print t, name, src; inm = 0; next }
  inm && name == "" && match($0, /^[ \t]+name:[ \t]*"[^"]*"/) { v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); name = v }
  inm && src == "" && match($0, /^[ \t]+src:[ \t]*"[^"]*"/) { v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); src = v }
' "$BP_SRC")
for s in $SERVICES; do
  P=$(svcexec "$s"); P=${P%% *}; b=${P##*/}
  [ "$(count "sh_binary $b bin/$b" "$MODS")" -ge 1 ] && ok "(f) $s: an sh_binary $b with src bin/$b" || no "(f) $s: no sh_binary named $b with src bin/$b in $BP_SRC (init cannot exec it)"
done
[ "$(count "prebuilt_etc nowhere.rc etc/nowhere.rc" "$MODS")" -ge 1 ] && ok "(f) a prebuilt_etc nowhere.rc with src etc/nowhere.rc" || no "(f) no prebuilt_etc named nowhere.rc with src etc/nowhere.rc in $BP_SRC"

# --- --mutate: each broken copy must fail the suite in the check it names (rc 1 -- not a harness exit) ------------
if [ "$MUTATE" = yes ]; then
  echo "== mutations =="
  # mutate <label> <case letter> <rc|bp|roamd> <old> <new> [<old> <new> ...]: replace the first <old> of each pair in a
  # copy of that input. Convicted only by rc 1 AND a "FAIL  (<x>) " line for the named letter.
  mutate(){
    local label="$1" c="$2" kind="$3" m out rc src; shift 3
    case "$kind" in rc) src="$RC_SRC" ;; bp) src="$BP_SRC" ;; roamd) src="$ROAMD_SRC" ;; esac
    m=$(mktemp -p "$W"); out=$(mktemp -p "$W")
    python3 -I - "$src" "$m" "$@" <<'PY'
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
    bash "$SELF" "--$kind=$m" > "$out" 2>&1; rc=$?
    case "$rc" in
      1) if grep -qF "  FAIL  ($c) " "$out"; then ok "mutation convicted by ($c): $label"
         else no "mutation '$label' exited 1 but did not FAIL ($c)"; fi ;;
      0) no "mutation SURVIVED: $label" ;;
      *) no "mutation '$label' hit a harness exit (rc $rc), not a conviction" ;;
    esac
  }
  RO_HEAD='service nowhere_roamd_ro /system/bin/nowhere_roamd.sh ro
    class late_start
    user root
    group root
'
  CRED_HEAD='service nowhere_roamd_cred /system/bin/nowhere_roamd.sh cred
    class late_start
    user root
    group root
'
  MEDIAD_HEAD='service nowhere_mediad /system/bin/nowhere_mediad.sh
    class late_start
    user root
    group root inet
'
  mutate "R1: inet added to nowhere_roamd_ro's group" d rc "$RO_HEAD" "${RO_HEAD%root
}root inet
"
  mutate "R2: inet added to nowhere_roamd_cred's group" d rc "$CRED_HEAD" "${CRED_HEAD%root
}root inet
"
  mutate "R3: inet removed from nowhere_mediad's group" d rc "$MEDIAD_HEAD" "${MEDIAD_HEAD% inet
}
"
  mutate "R4: oneshot removed from nowhere_mediad" c rc "${MEDIAD_HEAD}    oneshot
" "$MEDIAD_HEAD"
  mutate "R5: oneshot added to nowhere_login" b rc '    seclabel u:r:nowhere:s0
    disabled
' '    seclabel u:r:nowhere:s0
    oneshot
    disabled
'
  mutate "R6: the login socket mode 0666 -> 0660" b rc \
    'socket nowhere_login stream 0666 ' 'socket nowhere_login stream 0660 '
  mutate "R7: a socket line added to nowhere_gate" b rc 'service nowhere_gate /system/bin/nowhere_gate.sh
    class late_start
' 'service nowhere_gate /system/bin/nowhere_gate.sh
    class late_start
    socket nowhere_gate stream 0660 root root
'
  mutate "R8: nowhere_roamd_ro's argument ro -> readonly" e rc \
    'service nowhere_roamd_ro /system/bin/nowhere_roamd.sh ro
' 'service nowhere_roamd_ro /system/bin/nowhere_roamd.sh readonly
'
  mutate "R9: roamd's cred) lane arm renamed" e roamd \
    '  cred) REQ="$STATE/roamcred.req"' '  credlane) REQ="$STATE/roamcred.req"'
  mutate "R10: the nowhere_gate.sh sh_binary removed from Android.bp" f bp 'sh_binary {
    name: "nowhere_gate.sh",
    src: "bin/nowhere_gate.sh",
}
' ''

  # Harness probes: a parse that does not find the eight services, and a missing input, must each exit 2.
  probe(){
    local label="$1" rc; shift
    bash "$SELF" "$@" > "$(mktemp -p "$W")" 2>&1; rc=$?
    [ "$rc" -eq 2 ] && ok "harness probe exits 2: $label" || no "harness probe '$label' exited $rc, want 2"
  }
  H1=$(mktemp -p "$W")
  if python3 -I - "$RC_SRC" "$H1" <<'PY'
import sys
s = open(sys.argv[1]).read()
if "service nowhere_gate " not in s:
    sys.exit(3)
open(sys.argv[2], "w").write(s.replace("service nowhere_gate ", "service nowhere_gatex ", 1))
PY
  then probe "H1: an unknown service name in the rc" "--rc=$H1"
  else no "harness probe 'H1' did not apply"; fi
  probe "H2: a missing Android.bp" "--bp=$W/no-such-Android.bp"
fi

echo "test-rc-services: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
