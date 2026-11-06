#!/usr/bin/env bash
# test-chooser-tethering-find.sh [--mutate] -- the gate may look up the tethering service (NWP-20261113-07).
#
# WHY COMMITTED. nowhere_chooser is built with app_domain() alone, which grants no service_manager find, so every
# system service the gate touches is granted by hand in core/vendor-common/sepolicy/nowhere.te. Without the
# tethering_service find, TetheringManager never gets its connector: every hotspot, USB and Bluetooth tethering
# start from a signed-in profile is queued and retried silently, START answers `ERR-HS timeout` after 10 s, and the
# denial floods the log ring every ~200 ms (frankel 0.5.48 and lynx 2026102201, 2026-10-22). Nothing breaks at build
# time when the line goes, so this pins it as text:
#   1. the exact allow line appears exactly once, uncommented, in nowhere.te;
#   2. no neverallow in core/ or editions/ sepolicy names nowhere_chooser with tethering_service;
#   3. the deviceidle_service find is still there -- a control that must match, so a broken grep cannot pass.
# The policy compile (the real neverallow check) and the device proof are the build host's: the line lands in
# system_ext and needs a system_ext flash.
#
#   bash test-chooser-tethering-find.sh            # the checks
#   bash test-chooser-tethering-find.sh --mutate   # ... plus broken copies that must each be CONVICTED
#
# TE=<file> and POLICY_DIRS="<dir> ..." override the inputs (a mutant copy, or origin/main's nowhere.te).
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TE="${TE:-$ROOT/core/vendor-common/sepolicy/nowhere.te}"
POLICY_DIRS="${POLICY_DIRS:-$ROOT/core $ROOT/editions}"
[ -f "$TE" ] || { echo "no such file: $TE" >&2; exit 2; }
for d in $POLICY_DIRS; do [ -d "$d" ] || { echo "no such dir: $d" >&2; exit 2; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

LINE='allow nowhere_chooser tethering_service:service_manager find;'
CONTROL='allow nowhere_chooser deviceidle_service:service_manager find;'
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# The exact line, a whole line, exactly once: -x does not count a commented or reshaped copy.
c_line(){ local n; n=$(grep -cxF -- "$LINE" "$1"); [ "$n" = 1 ]; }
# Every *.te under the dirs, comments stripped, split into statements on ';' (a neverallow may span lines).
c_never(){
  local files hit
  files=$(find "$@" -name '*.te' -type f 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086
  hit=$(sed 's/#.*//' $files | tr '\n' ' ' | tr ';' '\n' \
        | awk '$1 == "neverallow" && /nowhere_chooser/ && /tethering_service/ { print }')
  [ -z "$hit" ]
}
c_control(){ local n; n=$(grep -cxF -- "$CONTROL" "$1"); [ "$n" = 1 ]; }

echo "== the gate may look up tethering_service =="
c_line "$TE"           && ok "nowhere.te holds '$LINE' exactly once, uncommented" \
                       || no "the tethering_service find is missing, commented out, reshaped or duplicated in $TE"
# shellcheck disable=SC2086
c_never $POLICY_DIRS   && ok "no neverallow names nowhere_chooser with tethering_service" \
                       || no "a neverallow in the policy names nowhere_chooser with tethering_service"
c_control "$TE"        && ok "control: the deviceidle_service find is still present" \
                       || no "control: the deviceidle_service find is gone -- the check itself cannot be trusted"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  mut(){ # mut <label> <check> <sed-expr>  -- on a copy of TE
    local x; x=$(mktemp -p "$W")
    if ! sed "$3" "$TE" > "$x" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$TE" "$x"; then no "MUTATION INERT: $1"; return; fi
    if "$2" "$x"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi
  }
  mut "the line deleted"                         c_line    '/^allow nowhere_chooser tethering_service:service_manager find;$/d'
  mut "the line commented out"                   c_line    's/^allow nowhere_chooser tethering_service/# &/'
  mut "the domain changed to nowhere"            c_line    's/^allow nowhere_chooser tethering_service/allow nowhere tethering_service/'
  mut "the class changed to binder"              c_line    '/tethering_service/s/:service_manager find;/:binder find;/'
  mut "the line duplicated"                      c_line    '/^allow nowhere_chooser tethering_service:service_manager find;$/p'
  mut "the control (deviceidle_service) deleted" c_control '/^allow nowhere_chooser deviceidle_service:service_manager find;$/d'
  # A neverallow spread over lines, planted in a copy of the policy dirs' nowhere.te.
  nd=$(mktemp -d -p "$W")
  cp "$TE" "$nd/nowhere.te"
  printf 'neverallow nowhere_chooser {\n    tethering_service # planted\n}:service_manager find;\n' >> "$nd/nowhere.te"
  if c_never "$nd"; then no "NOT CONVICTED: a multi-line neverallow planted"; else ok "convicted: a multi-line neverallow planted"; fi
  # ... and one only in a comment must not count.
  cp "$TE" "$nd/nowhere.te"
  printf '# neverallow nowhere_chooser tethering_service:service_manager find;\n' >> "$nd/nowhere.te"
  if c_never "$nd"; then ok "a commented neverallow is not a neverallow"; else no "a commented neverallow was read as a statement"; fi
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
