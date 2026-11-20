#!/usr/bin/env bash
# test-endospore-priv-phone-nfc-grants.sh [--mutate] -- roamd may reach the phone, netpolicy and nfc services on an
# Endospore USER build (NWP-20261210-15).
#
# WHY COMMITTED. roamd runs as endospore_priv on a USER build. md_write runs `cmd phone data`, dt_read/dt_write run
# `cmd netpolicy`, `dumpsys nfc` and `svc nfc`. The find of radio_service was SEEN denied on lynx 2026102901
# (enforcing, NWP-20261029-24): `mobile_data=1 NOT APPLIED (reads 0)`. The netpolicy and nfc grants are inferred
# from the policy. Nothing breaks at build time when one of these lines goes, so this pins them as text:
#   a. each of the ten grant lines appears exactly once, as a whole uncommented line, in endospore.te;
#   b. the live lines of endospore.te that name radio_service, netpolicy_service, nfc_service or the domains radio
#      or nfc are EXACTLY those ten lines, so a widened grant fails (radio_data_file is a different word);
#   c. no neverallow in core/ or editions/ sepolicy names endospore_priv with radio_service, nfc_service or
#      netpolicy_service;
#   d. the bluetooth_manager_service find is still there -- a control that must match, so a broken grep cannot pass.
# The policy compile (the real neverallow check) and the device proof are the build host's.
#
#   bash test-endospore-priv-phone-nfc-grants.sh            # the checks
#   bash test-endospore-priv-phone-nfc-grants.sh --mutate   # ... plus broken copies that must each be CONVICTED
#
# TE=<file> and POLICY_DIRS="<dir> ..." override the inputs (a mutant copy, or origin/main's endospore.te).
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TE="${TE:-$ROOT/editions/endospore/vendor/sepolicy/endospore.te}"
POLICY_DIRS="${POLICY_DIRS:-$ROOT/core $ROOT/editions}"
[ -f "$TE" ] || { echo "no such file: $TE" >&2; exit 2; }
for d in $POLICY_DIRS; do [ -d "$d" ] || { echo "no such dir: $d" >&2; exit 2; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

LINES=$(mktemp -p "$W")
cat > "$LINES" <<'EOF'
allow endospore_priv radio_service:service_manager find;
binder_call(endospore_priv, radio)
allow radio endospore_priv:binder call;
allow radio endospore_priv:fd use;
allow endospore_priv netpolicy_service:service_manager find;
allow endospore_priv nfc_service:service_manager find;
binder_call(endospore_priv, nfc)
allow nfc endospore_priv:binder call;
allow nfc endospore_priv:fd use;
allow nfc endospore_priv:fifo_file write;
EOF
CONTROL='allow endospore_priv bluetooth_manager_service:service_manager find;'
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# (a) every grant line, a whole line, exactly once: -x does not count a commented or reshaped copy.
c_lines(){
  local l n bad=0
  while IFS= read -r l; do
    n=$(grep -cxF -- "$l" "$1")
    [ "$n" = 1 ] || { echo "    (a) '$l' found $n times"; bad=1; }
  done < "$LINES"
  [ "$bad" = 0 ]
}
# (b) the live lines (comments stripped, trailing blanks trimmed) that name one of the five words, as whole words
# split on every non-identifier character, must be exactly the ten grant lines.
c_surface(){
  local got want
  got=$(sed 's/#.*//; s/[[:space:]]*$//' "$1" | awk '{
          n = split($0, t, /[^A-Za-z0-9_]+/)
          for (i = 1; i <= n; i++)
            if (t[i] == "radio_service" || t[i] == "netpolicy_service" || t[i] == "nfc_service" ||
                t[i] == "radio" || t[i] == "nfc") { print; next }
        }' | LC_ALL=C sort)
  want=$(LC_ALL=C sort "$LINES")
  [ "$got" = "$want" ] && return 0
  echo "    (b) the live surface differs from the ten grant lines:"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed -n 's/^[<>].*/      &/p'
  return 1
}
# (c) every *.te under the dirs, comments stripped, split into statements on ';' (a neverallow may span lines).
# A macro call such as binder_call(a, b) has no ';', so the text before a neverallow in one record can be a macro
# call, in the same file or at the end of the file before it (the files are joined). So the check finds the word
# neverallow anywhere in a record and reads only the text from that word on, not only a record that starts with it.
c_never(){
  local files hit
  files=$(find "$@" -name '*.te' -type f 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086
  hit=$(sed 's/#.*//' $files | tr '\n' ' ' | tr ';' '\n' \
        | awk '{ s = " " $0 " "
                 p = match(s, /[^A-Za-z0-9_]neverallow[^A-Za-z0-9_]/)
                 if (!p) next
                 s = substr(s, p + 1)
                 n = split(s, t, /[^A-Za-z0-9_]+/); ep = 0; sv = 0
                 for (i = 1; i <= n; i++) {
                   if (t[i] == "endospore_priv") ep = 1
                   if (t[i] == "radio_service" || t[i] == "nfc_service" || t[i] == "netpolicy_service") sv = 1
                 }
                 if (ep && sv) print s }')
  [ -z "$hit" ]
}
# (d) the control.
c_control(){ local n; n=$(grep -cxF -- "$CONTROL" "$1"); [ "$n" = 1 ]; }

echo "== endospore_priv may reach the phone, netpolicy and nfc services =="
c_lines "$TE"          && ok "(a) endospore.te holds each of the ten grant lines exactly once, uncommented" \
                       || no "(a) a grant line is missing, commented out, reshaped or duplicated in $TE"
c_surface "$TE"        && ok "(b) no other live line names radio_service, netpolicy_service, nfc_service, radio or nfc" \
                       || no "(b) the radio/netpolicy/nfc surface of $TE is not exactly the ten grant lines"
# shellcheck disable=SC2086
c_never $POLICY_DIRS   && ok "(c) no neverallow names endospore_priv with radio_service, nfc_service or netpolicy_service" \
                       || no "(c) a neverallow in the policy names endospore_priv with one of the three services"
c_control "$TE"        && ok "(d) control: the bluetooth_manager_service find is still present" \
                       || no "(d) control: the bluetooth_manager_service find is gone -- the check itself cannot be trusted"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  mut(){ # mut <label> <check> <sed-expr>  -- on a copy of TE
    local x; x=$(mktemp -p "$W")
    if ! sed "$3" "$TE" > "$x" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$TE" "$x"; then no "MUTATION INERT: $1"; return; fi
    if "$2" "$x" >/dev/null; then no "NOT CONVICTED: $1"; else ok "convicted by $2: $1"; fi
  }
  mut "G1 the radio_service find deleted"            c_lines   '/^allow endospore_priv radio_service:service_manager find;$/d'
  mut "G2 binder_call(endospore_priv, radio) commented out" c_lines 's/^binder_call(endospore_priv, radio)$/# &/'
  mut "G3 the radio callback line deleted"           c_lines   '/^allow radio endospore_priv:binder call;$/d'
  mut "G4 the netpolicy find duplicated"             c_lines   '/^allow endospore_priv netpolicy_service:service_manager find;$/p'
  mut "G5 the nfc fifo_file line deleted"            c_lines   '/^allow nfc endospore_priv:fifo_file write;$/d'
  mut "G6 a radio binder grant to endospore_priv appended" c_surface '$a allow endospore_priv radio:binder { call transfer };'
  mut "G7 a widened nfc_service grant appended"      c_surface '$a allow endospore_priv nfc_service:service_manager { find add };'
  mut "G9 the control (bluetooth_manager_service) deleted" c_control '/^allow endospore_priv bluetooth_manager_service:service_manager find;$/d'
  # G8: a neverallow spread over lines, planted in a copy of endospore.te in its own dir.
  nd=$(mktemp -d -p "$W")
  cp "$TE" "$nd/endospore.te"
  printf 'neverallow endospore_priv {\n    radio_service # planted\n}:service_manager find;\n' >> "$nd/endospore.te"
  if c_never "$nd"; then no "NOT CONVICTED: G8 a multi-line neverallow planted"; else ok "convicted by c_never: G8 a multi-line neverallow planted"; fi
  # G10: the same neverallow after a macro call that has no ';' (the reproduction in RF-001).
  cp "$TE" "$nd/endospore.te"
  printf 'binder_call(endospore_priv, system_server)\nneverallow endospore_priv {\n radio_service\n}:service_manager find;\n' >> "$nd/endospore.te"
  if c_never "$nd"; then no "NOT CONVICTED: G10 a neverallow after a macro call"; else ok "convicted by c_never: G10 a neverallow after a macro call"; fi
  # G11: a file that ends in a macro call, then a neverallow at the top of the next file.
  cp "$TE" "$nd/endospore.te"
  printf 'binder_call(endospore_priv, system_server)\n' > "$nd/a.te"
  printf 'neverallow endospore_priv nfc_service:service_manager find;\n' > "$nd/b.te"
  if c_never "$nd"; then no "NOT CONVICTED: G11 a neverallow after a macro call at the end of the file before it"
  else ok "convicted by c_never: G11 a neverallow after a macro call at the end of the file before it"; fi
  rm -f "$nd/a.te" "$nd/b.te"
  # ... and a macro that names the services before a neverallow that does not must not count.
  cp "$TE" "$nd/endospore.te"
  printf 'some_macro(endospore_priv, radio_service)\nneverallow untrusted_app system_file:file write;\n' >> "$nd/endospore.te"
  if c_never "$nd"; then ok "a macro before an unrelated neverallow is not read as part of it"
  else no "a macro before an unrelated neverallow was read as part of it"; fi
  # ... and one only in a comment must not count.
  cp "$TE" "$nd/endospore.te"
  printf '# neverallow endospore_priv radio_service:service_manager find;\n' >> "$nd/endospore.te"
  if c_never "$nd"; then ok "a commented neverallow is not a neverallow"; else no "a commented neverallow was read as a statement"; fi
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
