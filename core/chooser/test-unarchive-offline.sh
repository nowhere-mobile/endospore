#!/usr/bin/env bash
# test-unarchive-offline.sh [--mutate] -- a failed on-demand materialise reports NO_CONNECTIVITY when offline.
#
# WHAT IS UNDER TEST. docs/app-persistence-ondemand.md requires a clear "connect to the internet" message on an
# offline first tap, never a silent failure. The platform renders that dialog itself when the installer of record
# reports PackageInstaller.UNARCHIVAL_ERROR_NO_CONNECTIVITY. Two parts:
#   - UnarchiveService.unarchivalErrorCode is RUN under a real JVM (extracted verbatim, brace-matched, wrapped in
#     `Lifted` with a stub PackageInstaller carrying the two constants): offline -> NO_CONNECTIVITY, online -> GENERIC.
#   - Both failure call sites (the worker's finally in UnarchiveService, and UnarchiveReceiver) must route through
#     that helper; a source check fails if either reports the GENERIC literal again.
#
# It needs a JDK, and it FAILS when there is none (exit 2): a skip would read green on a runner that never ran it.
#
#   bash test-unarchive-offline.sh              # the truth table and the call-site check
#   bash test-unarchive-offline.sh --mutate     # ... plus mutations that must each CONVICT the suite
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/src/com/nowhere/chooser"
SVC="$SRC/UnarchiveService.java"
RCV="$SRC/UnarchiveReceiver.java"
MUTATE=0
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=1 ;;
    *) echo "usage: $0 [--mutate]" >&2; exit 2 ;;
  esac
done

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-unarchive-offline: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract() { # extract <file> <signature-fragment> -- the member, brace-matched
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + ' in ' + sys.argv[1] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

sites() { # sites <svc> <rcv> -- 0 when both failure call sites route through the helper
  local sv rc
  sv=$(extract "$1" 'if (!ok && unarchiveId >= 0)') || return 3
  rc=$(extract "$2" 'if (unarchiveId >= 0)') || return 3
  case "$sv" in *'unarchivalErrorCode(hasValidatedNetwork('*) ;; *) echo "  FAIL  worker finally bypasses the helper"; return 1 ;; esac
  case "$rc" in *'unarchivalErrorCode(UnarchiveService.hasValidatedNetwork('*) ;; *) echo "  FAIL  receiver bypasses the helper"; return 1 ;; esac
  case "$sv$rc" in *UNARCHIVAL_GENERIC_ERROR*) echo "  FAIL  a call site reports the GENERIC literal"; return 1 ;; esac
  echo "  PASS  both call sites route through unarchivalErrorCode(hasValidatedNetwork(..))"
}

build() { # build <svc> -> compiled into $WORK
  rm -f "$WORK/UnarchiveOffline.java" "$WORK"/*.class
  {
    echo 'final class PackageInstaller {'
    echo '  static final int UNARCHIVAL_GENERIC_ERROR = 1, UNARCHIVAL_ERROR_NO_CONNECTIVITY = 4;'
    echo '}'
    echo 'final class Lifted {'
    extract "$1" 'static int unarchivalErrorCode(boolean' || return 3
    echo '}'
    cat <<'JAVA'
public class UnarchiveOffline {
  static int fails = 0;
  static void eq(String what, int got, int want) {
    if (got == want) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": got " + got + ", want " + want); fails++; }
  }
  public static void main(String[] a) {
    System.out.println("-- unarchivalErrorCode");
    eq("no validated network -> NO_CONNECTIVITY", Lifted.unarchivalErrorCode(false), PackageInstaller.UNARCHIVAL_ERROR_NO_CONNECTIVITY);
    eq("validated network -> GENERIC_ERROR", Lifted.unarchivalErrorCode(true), PackageInstaller.UNARCHIVAL_GENERIC_ERROR);
    System.out.println(fails == 0 ? "helper passed" : "helper FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$WORK/UnarchiveOffline.java" || return 3
  "$JAVAC" -nowarn -d "$WORK" "$WORK/UnarchiveOffline.java" 2>"$WORK/javac.err" || return 4
}

suite() { # suite <svc> <rcv> [quiet] -> 0 pass, 1 fail, 3 extraction failed, 4 compile failed
  local q=${3:-} rc=0 out
  build "$1"; local b=$?
  if [ "$b" = 3 ]; then [ "$q" = quiet ] || echo "EXTRACTION FAILED"; return 3; fi
  if [ "$b" != 0 ]; then [ "$q" = quiet ] || { echo "compile failed:"; head -5 "$WORK/javac.err"; }; return 4; fi
  out=$("$JAVA" -cp "$WORK" UnarchiveOffline) || rc=1
  [ "$q" = quiet ] || echo "$out"
  out=$(sites "$1" "$2"); local s=$?
  [ "$s" = 3 ] && { [ "$q" = quiet ] || echo "EXTRACTION FAILED"; return 3; }
  [ "$q" = quiet ] || echo "$out"
  [ "$s" = 0 ] || rc=1
  return $rc
}

suite "$SVC" "$RCV"; RC=$?
[ "$RC" -ge 3 ] && exit 2
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <which: svc|rcv> <sed script>
  local s="$SVC" r="$RCV" orig m="$WORK/mut-$2.java"
  case "$2" in svc) orig=$SVC; s=$m ;; rcv) orig=$RCV; r=$m ;; esac
  sed "$3" "$orig" > "$m"
  if cmp -s "$orig" "$m"; then printf '  ⚠ NOT APPLIED %s (the pattern no longer matches)\n' "$1"; MRC=1; return; fi
  suite "$s" "$r" quiet; local rc=$?
  case "$rc" in
    0) printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1 ;;
    1) printf '  convicted   %s\n' "$1" ;;
    *) printf '  ⚠ DID NOT BUILD %s\n' "$1"; MRC=1 ;;
  esac
}
mutant "M1 helper always GENERIC"                 svc '/static int unarchivalErrorCode(boolean/,/^    }/ s/return validatedNetwork ?/return true ?/'
mutant "M2 helper inverted"                       svc '/static int unarchivalErrorCode(boolean/,/^    }/ s/return validatedNetwork ?/return !validatedNetwork ?/'
mutant "M3 receiver reverted to the GENERIC literal" rcv 's/UnarchiveService.unarchivalErrorCode(UnarchiveService.hasValidatedNetwork(ctx))/PackageInstaller.UNARCHIVAL_GENERIC_ERROR/'
mutant "M4 worker finally reverted to the GENERIC literal" svc 's/unarchivalErrorCode(hasValidatedNetwork(this))/PackageInstaller.UNARCHIVAL_GENERIC_ERROR/'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
