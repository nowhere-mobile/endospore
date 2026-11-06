#!/usr/bin/env bash
# test-chooser-service-finds.sh [--mutate] -- the gate may look up the clipboard and location services
# (NWP-20261127-14).
#
# WHY COMMITTED. nowhere_chooser is built with app_domain() alone, which grants no service_manager find, so every
# system service the chooser touches is granted by hand in core/vendor-common/sepolicy/nowhere.te. Two of them:
#   - clipboard_service (Q041, decided 2026-10-20): without it getSystemService(ClipboardManager.class) is null,
#     so SafeEdit.withPaste never offers paste and a buyer cannot paste a claim code into the claim box.
#   - location_service: without it ChooserActivity.scanWifi gets a null LocationManager, sleeps all ten 300 ms
#     ticks (3 s more on every scan) and words every empty list "can't scan for networks yet".
# Nothing breaks at build time when a line goes, so this pins each one as text:
#   1. the exact allow line appears exactly once, uncommented, in nowhere.te;
#   2. no neverallow in core/ or editions/ sepolicy names nowhere_chooser with that service;
# and once:
#   3. the deviceidle_service find is still there -- a control that must match, so a broken grep cannot pass.
# The policy compile (the real neverallow check) and the device proof are the build host's: the lines land in
# system_ext and need a system_ext flash.
#
#   bash test-chooser-service-finds.sh            # the checks
#   bash test-chooser-service-finds.sh --mutate   # ... plus broken copies that must each be CONVICTED
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

SERVICES='clipboard_service location_service'
CONTROL='allow nowhere_chooser deviceidle_service:service_manager find;'
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

line_of(){ printf 'allow nowhere_chooser %s:service_manager find;' "$1"; }
# c_line <file> <service>: the exact line, a whole line, exactly once (-x does not count a commented or
# reshaped copy).
c_line(){ local n l; l=$(line_of "$2"); n=$(grep -cxF -- "$l" "$1"); [ "$n" = 1 ]; }
# c_never <service> <dir...>: every *.te under the dirs, comments stripped, split into statements on ';' (a
# neverallow may span lines).
c_never(){
  local svc files hit
  svc=$1; shift
  files=$(find "$@" -name '*.te' -type f 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086
  hit=$(sed 's/#.*//' $files | tr '\n' ' ' | tr ';' '\n' \
        | awk -v s="$svc" '$1 == "neverallow" && /nowhere_chooser/ && index($0, s) { print }')
  [ -z "$hit" ]
}
c_control(){ local n; n=$(grep -cxF -- "$CONTROL" "$1"); [ "$n" = 1 ]; }

for s in $SERVICES; do
  echo "== the gate may look up $s =="
  c_line "$TE" "$s"          && ok "nowhere.te holds '$(line_of "$s")' exactly once, uncommented" \
                             || no "the $s find is missing, commented out, reshaped or duplicated in $TE"
  # shellcheck disable=SC2086
  c_never "$s" $POLICY_DIRS  && ok "no neverallow names nowhere_chooser with $s" \
                             || no "a neverallow in the policy names nowhere_chooser with $s"
done
echo "== control =="
c_control "$TE"              && ok "control: the deviceidle_service find is still present" \
                             || no "control: the deviceidle_service find is gone -- the check itself cannot be trusted"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  mut(){ # mut <label> <check> <service|-> <sed-expr>  -- on a copy of TE
    local x
    x=$(mktemp -p "$W")
    if ! sed "$4" "$TE" > "$x" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$TE" "$x"; then no "MUTATION INERT: $1"; return; fi
    if [ "$3" = - ]; then
      if "$2" "$x"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi
    else
      if "$2" "$x" "$3"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi
    fi
  }
  mut_never(){ # mut_never <service>  -- a neverallow planted in a copy of TE, in a dir of its own
    local s nd
    s=$1
    nd=$(mktemp -d -p "$W")
    cp "$TE" "$nd/nowhere.te"
    printf 'neverallow nowhere_chooser {\n    %s # planted\n}:service_manager find;\n' "$s" >> "$nd/nowhere.te"
    if c_never "$s" "$nd"; then no "NOT CONVICTED: $s: a multi-line neverallow planted"
    else ok "convicted: $s: a multi-line neverallow planted"; fi
    # ... and one only in a comment must not count.
    cp "$TE" "$nd/nowhere.te"
    printf '# neverallow nowhere_chooser %s:service_manager find;\n' "$s" >> "$nd/nowhere.te"
    if c_never "$s" "$nd"; then ok "$s: a commented neverallow is not a neverallow"
    else no "$s: a commented neverallow was read as a statement"; fi
  }
  for s in $SERVICES; do
    mut "$s: the line deleted"              c_line "$s" "/^allow nowhere_chooser $s:service_manager find;\$/d"
    mut "$s: the line commented out"        c_line "$s" "s/^allow nowhere_chooser $s/# &/"
    mut "$s: the domain changed to nowhere" c_line "$s" "s/^allow nowhere_chooser $s/allow nowhere $s/"
    mut "$s: the class changed to binder"   c_line "$s" "/^allow nowhere_chooser $s:/s/:service_manager find;/:binder find;/"
    mut "$s: the line duplicated"           c_line "$s" "/^allow nowhere_chooser $s:service_manager find;\$/p"
    mut_never "$s"
  done
  mut "the control (deviceidle_service) deleted" c_control - '/^allow nowhere_chooser deviceidle_service:service_manager find;$/d'
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
