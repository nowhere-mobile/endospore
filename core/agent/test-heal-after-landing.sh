#!/usr/bin/env bash
# test-heal-after-landing.sh [--mutate] -- the vault heal of unkept apps runs after landing (NWP-20261202-17, backlog:
# Stop the media split in the CE vault and `#de`; keep it for `#media`, its #2 part). roamd `in` exports
# NOWHERE_HEAL_AFTER_LANDING=1; restoreHeal then leaves the vault's deferred entries of apps NOT in the keep set
# deferred ("after landing", not on the heal list), and mediad's healLate (media_heal_late.go) lands them after landing:
# the package dir's owner, the recorded mode and mtime, a rename that never replaces, the tombstone after the rename.
# Kept apps and #de still heal in the sign-in.
#
# The Go half runs media_heal_late_test.go. The shell half checks that the `in` arm of nowhere_roamd.sh exports the flag
# exactly once, on the line right after the NOWHERE_HEAL_UNTIL export.
# --mutate breaks each guard in turn on a COPY (the Go package or the roamd script); each mutant must be CONVICTED (the
# Go ones by a real `--- FAIL`). One that fails to apply or compile is a failure. M12-M17 pin the two races: a seal that
# walks a dir before the landing's rename keeps the file (the .landed line), and an unlink of the stub during the
# landing is never undone (landMu, which mediaRoot.Unlink also takes).
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='HealAfterLanding|LateHeal|HealLate'
ROAMD=../vendor-common/bin/nowhere_roamd.sh
[ -f "$ROAMD" ] || { echo "no such script: $ROAMD" >&2; exit 2; }
L_HU='    export NOWHERE_HEAL_UNTIL=$(( $(date +%s) + 2400 ))'
L_AL='    export NOWHERE_HEAL_AFTER_LANDING=1   # NWP-20261202-17: the vault heal of unkept apps runs in mediad after landing (media_heal_late.go); kept apps and #de still heal here'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

# roamd_ok <script> [quiet] -> 0 when the in arm exports the flag once, right after the NOWHERE_HEAL_UNTIL export
roamd_ok() {
  local f="$1" quiet="${2:-}" pairs total
  pairs=$(awk -v HU="$L_HU" -v AL="$L_AL" '$0 == "  in)" {a=1} a && prev == HU && $0 == AL {n++} {prev=$0} END {print n+0}' "$f")
  total=$(awk -v AL="$L_AL" '$0 == AL {n++} END {print n+0}' "$f")
  if [ "$pairs" = 1 ] && [ "$total" = 1 ]; then
    [ -n "$quiet" ] || echo "  ok    the in arm exports NOWHERE_HEAL_AFTER_LANDING=1 once, right after NOWHERE_HEAL_UNTIL"
    return 0
  fi
  [ -n "$quiet" ] || echo "  FAIL  the in arm's NOWHERE_HEAL_AFTER_LANDING export: $pairs after NOWHERE_HEAL_UNTIL, $total in all (want 1 and 1)"
  return 1
}
roamd_ok "$ROAMD" || { echo "shell half FAILED"; exit 1; }
echo "shell half passed"
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST be convicted) =="
fails=0
# mut <label> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real `--- FAIL`
mut() {
  local label=$1 file=$2 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
# smut <label> <sed args...>: a COPY of roamd, refused when the sed changed nothing; convicted by roamd_ok
smut() {
  local label="$1" m; shift
  m=$(mktemp -p "$W") || { fails=$((fails+1)); return; }
  sed "$@" "$ROAMD" > "$m"
  if cmp -s "$ROAMD" "$m"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -f "$m"; return; fi
  if roamd_ok "$m" quiet; then echo "  SURVIVED  $label"; fails=$((fails+1)); else echo "  convicted $label"; fi
  rm -f "$m"
}

# M1: TestHealAfterLandingRestoreFetchesNothing, "flag on, no keep file: fetched ..." (the restore fetches every file).
mut "M1 restoreHeal ignores the flag" media_heal.go \
  '"NOWHERE_HEAL_AFTER_LANDING"\) != "1"' '"NOWHERE_HEAL_AFTER_LANDING_IGNORED") != "1"'
# M2: TestHealAfterLandingRestoreFetchesNothing, "flag on: handled ..."; TestSealDuring...: b and c DROPPED by the seal.
mut "M2 late rels go into handledRels" media_heal.go \
  '\n(\t+)stay\(rel, "after landing"\)' '\n\1res.handledRels = append(res.handledRels, rel)\n\1stay(rel, "after landing")'
# M3: TestHealAfterLandingRestoreFetchesNothing, "#de with the flag: ... want all 3 fetchable files fetched".
mut "M3 the bare-vault check dropped" media_heal.go \
  'strings\.Contains\(profile, "#"\)' 'strings.Contains(profile, "#never#")'
# M4: TestHealLateKeepsStubOnFailure/rename, "the stub was tombstoned though nothing landed".
mut "M4 markDeleted before the rename" media_heal_late.go \
  '\n(\t+)if err := healLateRename\(tmpName, dst\); err != nil \{' '\n\1_ = s.markDeleted(rel)\n\1if err := healLateRename(tmpName, dst); err != nil {'
# M5: TestHealLateNeverReplacesARealFile, "the late heal replaced a real file".
mut "M5 healLateRename = os.Rename" media_heal_late.go \
  'var healLateRename = renameNoReplace' 'var healLateRename = os.Rename'
# M6: TestHealLateKeepsStubOnFailure/chown, "want the file left with reason \"owner\"" and "a file was landed".
mut "M6 the chown failure ignored" media_heal_late.go \
  'if err := materializeChown\(tmpName, uid, gid\); err != nil \{' 'if err := materializeChown(tmpName, uid, gid); err != nil && false {'
# M7: TestHealLateKeepsStubOnFailure/space, "want the file left with reason \"space\"" and "a file was landed".
mut "M7 the space check removed" media_heal_late.go \
  'free-2\*d\.Size < reserve' 'free+2*d.Size < reserve'
# M8: TestHealLateVaultOnly, "#media: ... must leave a scope that still defers alone".
mut "M8 the scope gate in healLate removed" media_heal_late.go \
  'if scopeDefersMedia\(scope\) \{' 'if scopeDefersMedia(scope) && false {'
# M9: TestHealAfterLandingRestoreFetchesNothing, "flag on, app.kept kept: ... want the kept app's file fetched".
mut "M9 the keep-file test dropped from the restore predicate" media_heal.go \
  '_, kept := keep\[healPkgOf\(rel\)\]' '_, kept := keep[""]'
# M10: TestHealLateKeepsStubOnFailure/kept and /odhold, "want the file left with reason \"parked\"".
mut "M10 the parked skip dropped from healLate" media_heal_late.go \
  'if hasDir && healLateParked\(' 'if hasDir && false && healLateParked('
# M11: roamd_ok, "the in arm's NOWHERE_HEAL_AFTER_LANDING export".
smut "M11 the roamd export removed" -e '/^    export NOWHERE_HEAL_AFTER_LANDING=1 /d'
# M12: TestSealRacingLateHealKeepsTheLandedFile, "the new head holds it neither deferred nor essential" (RF-001).
mut "M12 the carry drops a late-landed tombstoned rel" main.go \
  'if tomb\[rel\] && !lateLandedUnwalked\(src, rel, lateLanded, seen\) \{' 'if tomb[rel] && len(lateLanded) >= 0 {'
# M13: TestSealDropsALateHealLandedFileTheAppDeleted, "a landed file that is not on disk must not be carried".
mut "M13 the on-disk check dropped from the carry" media_heal_late.go \
  'return err == nil && fi\.Mode\(\)\.IsRegular\(\)' 'return err == nil && fi.Mode().IsRegular() || len(landed) > 0'
# M14: TestHealLateNeverUndoesAnUnlink, "the late heal landed a file the app had unlinked" (RF-002).
mut "M14 the tombstone check under the lock removed" media_heal_late.go \
  '\n(\t+)if s\.isDeleted\(rel\) \{\n(\t+)return "deleted"' '\n\1if false {\n\2return "deleted"'
# M15: TestHealLateLandsUnderTheUnlinkLock, "the rename ran without landMu" (RF-002).
mut "M15 the landing does not take landMu" media_heal_late.go \
  '\n(\t+)s\.landMu\.Lock\(\)\n(\t+)defer s\.landMu\.Unlock\(\)' '\n'
# M16: TestHealLateLandsUnderTheUnlinkLock, "mediaRoot.Unlink must take r.srv.landMu before its tombstone check".
mut "M16 Unlink does not take landMu" mediafs.go \
  '\n(\t+)r\.srv\.landMu\.Lock\(\)\n(\t+)defer r\.srv\.landMu\.Unlock\(\)' '\n\1_ = 0'
# M17: TestHealLateLandsUnderTheUnlinkLock, ".landed ... want the landed rel"; TestSealRacingLateHeal... (RF-001).
mut "M17 the landing writes no .landed line" media_heal_late.go \
  'if err := s\.appendLanded\(rel\); err != nil \{' 'if err := error(nil); err != nil {'
[ "$fails" -eq 0 ] && echo "== all 17 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
