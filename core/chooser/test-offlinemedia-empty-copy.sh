#!/usr/bin/env bash
# test-offlinemedia-empty-copy.sh [<ProfileActivity.java>] [--mutate] -- NWP-20261013-45: the Offline-media
# screen's rows == 0 state says WHY it is empty (small files are kept on the phone) and quotes no size.
#
# WHY: the old copy, "No on-demand media -- everything's already local.", read as a broken screen on a profile
# whose media is all under the media floors (mediaFloorFor: 1 MiB user buckets, 8 MiB app /files/). Both floors
# are env-overridable (NOWHERE_MEDIA_MIN_USER, NOWHERE_MEDIA_MIN), so the copy must carry no number that can
# drift from the value in force.
#
#   bash test-offlinemedia-empty-copy.sh            # the invariants
#   bash test-offlinemedia-empty-copy.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }

# check <file>: prints the failures, exits non-zero on any.
check(){
  local f="$1" rc=0 line
  # The setText on the `none` view that follows the `rows == 0` test.
  line=$(awk '/if \(rows == 0\) \{/ {on=1} on && /none\.setText\(/ {print; exit}' "$f")
  if [ -z "$line" ]; then echo "  FAIL  no none.setText after 'rows == 0'"; return 1; fi
  case "$line" in *"kept on the phone"*) echo "  ok    empty state says small files are kept on the phone" ;;
    *) echo "  FAIL  empty state does not say 'kept on the phone'"; rc=1 ;; esac
  if grep -Eiq '[0-9][[:space:]]*(MiB|MB)' <<<"$line"; then
    echo "  FAIL  empty state quotes a size (the floors are env-overridable)"; rc=1
  else echo "  ok    empty state quotes no size"; fi
  case "$line" in *"already local"*) echo "  FAIL  old 'already local' copy is back"; rc=1 ;; esac
  return $rc
}

check "$SUT"; RC=$?
if [ "$MUTATE" = yes ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mut(){ # <name> <sed-expr>
    sed -E "$2" "$SUT" > "$T/m.java"
    if cmp -s "$SUT" "$T/m.java"; then echo "  FAIL  mutant '$1' did not apply"; RC=1; return; fi
    if out=$(check "$T/m.java"); then echo "  FAIL  mutant '$1' SURVIVED"; RC=1; else echo "  ok    mutant '$1' convicted"; fi
  }
  mut old-string 's/Nothing to manage here\. Smaller files are always kept on the phone[^"]*/No on-demand media — everything'"'"'s already local./'
  mut hardcoded-size 's/Smaller files are always/Files under 1 MiB are always/'
  mut dropped-reason 's/kept on the phone/stored/'
fi
[ "$RC" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$RC"
