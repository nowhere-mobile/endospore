#!/usr/bin/env bash
# test-status-words-java.sh [--mutate] -- NWP-20261122-19: the Software update words and the Locking wait line.
# Runs core/chooser/tests/status-words: ChooserActivity.otaApplyPhase / otaFailReason and ProfileActivity.coldLockWhy,
# compiled and EXECUTED, and pinned to the tokens nowhere_otad.sh and core/agent/main.go write
# (tests/status-words/run.sh says how).
#
# WHY THIS IS COMMITTED. These three helpers turn a daemon token into the only words the owner sees, and each side
# was tested alone: test-otad-apply.sh pins otad's PROG writes, coldlock_status_test.go the COLD-LOCK-STATUS line. A
# rename on the daemon side that updates its own test passes CI and silently changes the screen. If otad writes
# ph=oswriting, the screen shows "Working" for the whole ~40 min slot write (the hang #113 was built to explain). A
# new FAILED code from otaResState shows as a raw token. If COLD-LOCK-STATUS gains a field, or the seal op is renamed
# from "out", the "Finishing a backup first." line disappears, and a lock queued behind a seal says only "Locking…"
# for minutes (frankel 0.5.41, NWP-20261005-09).
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips would read green on a runner that never ran
# it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs it against deliberately broken
# copies, each of which must fail a CASE or a PIN (a copy that no longer extracts or compiles convicts nothing and is
# reported).
#
#   bash test-status-words-java.sh            # the cases and pins
#   bash test-status-words-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/status-words/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-status-words-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

echo "== $CH"
bash "$RUN" "$CH" "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by a case or a pin: a mutant that does not extract or compile proves nothing)"
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
# mut <label> <file under the repo root> <literal anchor> <replacement>: the anchor must occur exactly once in the
# file; it is replaced by the replacement (an empty replacement deletes the anchor).
mut() {
  local label="$1" rel="$2" anchor="$3" repl="$4" f n rc
  rm -rf "$W/c"
  mkdir -p "$W/c/core/chooser/src/com/nowhere/chooser" "$W/c/core/vendor-common/bin" "$W/c/core/agent"
  cp "$CH"/src/com/nowhere/chooser/*.java "$W/c/core/chooser/src/com/nowhere/chooser/"
  cp "$ROOT/core/vendor-common/bin/nowhere_otad.sh" "$W/c/core/vendor-common/bin/"
  cp "$ROOT/core/agent/main.go" "$ROOT/core/agent/coldlock_status_test.go" "$W/c/core/agent/"
  f="$W/c/$rel"
  n=$(A="$anchor" perl -0ne 'my $n = () = /\Q$ENV{A}\E/g; print $n' "$f")
  if [ "$n" != 1 ]; then echo "  BROKEN    $label -- the anchor occurs ${n:-?} time(s) in $rel, want 1"; return 1; fi
  if ! A="$anchor" R="$repl" perl -0pi -e 's/\Q$ENV{A}\E/$ENV{R}/' "$f"; then echo "  ERROR     $label -- perl failed"; return 1; fi
  if cmp -s "$f" "$ROOT/$rel"; then echo "  INERT     $label"; return 1; fi
  bash "$RUN" "$W/c/core/chooser" "$W/c" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  convicted $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
C=core/chooser/src/com/nowhere/chooser/ChooserActivity.java
P=core/chooser/src/com/nowhere/chooser/ProfileActivity.java
O=core/vendor-common/bin/nowhere_otad.sh
G=core/agent/main.go
fails=0
mut "M1 osverify shows the write's words"         $C 'case "osverify":    return "Checking the update";' \
                                                     'case "osverify":    return "Writing it to the phone";' || fails=$((fails+1))
mut "M2 the osdone case deleted"                  $C '            case "osdone":      return "Done — restarting";
' '' || fails=$((fails+1))
mut "M3 the ERR-STALE case deleted"               $C '            case "ERR-STALE":   return "the update stalled"; // worker died mid-run -> retry re-kicks a fresh apply
' '' || fails=$((fails+1))
mut "M4 every code reads unknown error"           $C 'default:            return code.isEmpty() ? "unknown error" : code;' \
                                                     'default:            return "unknown error";' || fails=$((fails+1))
mut "M5 the seal op read as seal"                 $P '"out".equals(f[1])' '"seal".equals(f[1])' || fails=$((fails+1))
mut "M6 a fourth field accepted"                  $P 'if (f.length != 3 || !"WAITING".equals(f[0]))' \
                                                     'if (f.length < 3 || !"WAITING".equals(f[0]))' || fails=$((fails+1))
mut "M7 one minute in the plural"                 $P 'min == 1 ? "1 minute"' 'min == 1 ? "1 minutes"' || fails=$((fails+1))
mut "M8 otad renames osverify"                    $O 'ph=osverify' 'ph=osverifying' || fails=$((fails+1))
mut "M9 the wait line gains a unit"               $G '"WAITING %s %d"' '"WAITING %s %ds"' || fails=$((fails+1))
mut "M10 otaResState gains a FAILED code"         $G 'case "ERR-RESTORE", "ERR-PAYLOAD", "ERR-APPLY", "ERR-CHECK":' \
                                                     'case "ERR-RESTORE", "ERR-PAYLOAD", "ERR-APPLY", "ERR-CHECK", "ERR-SPACE":' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
