#!/usr/bin/env bash
# test-index-refresh-gate-java.sh [--mutate] -- NWP-20261103-14: nApps asks the chooser for REFRESH-INDEX once per open,
# and the chooser spends data only behind the profile's "Download over mobile data" switch (Q079).
#
# WHY THIS IS COMMITTED. The chooser cannot be compiled off the build host. core/chooser/tests/index-refresh-gate/run.sh
# lifts the pure gate (StoreService.indexRefreshAllowed) and runs Cases under javac; the source checks below pin what a
# lift cannot see: refreshIndex is declared once, directly before materializeOwn, which is LAST since NWP-20261119-19
# (methods are only ever appended, so existing transaction codes stay unchanged), refreshIndex checks the caller and
# the gate before it sends REFRESH-INDEX, and StoreActivity calls it off the main thread inside a catch of Throwable.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else the build host's JDK below.
#
#   bash test-index-refresh-gate-java.sh            # the checks and the cases
#   bash test-index-refresh-gate-java.sh --mutate   # ... plus broken copies that must each FAIL the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export NWP_WORK="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SVC="$root/core/chooser/src/com/nowhere/chooser/StoreService.java"
AIDL="$root/core/chooser/aidl/com/nowhere/chooser/INowhereStore.aidl"
APP="$root/core/napps/src/com/nowhere/napps/StoreActivity.java"
RUN="$root/core/chooser/tests/index-refresh-gate/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SVC" ] && [ -f "$AIDL" ] && [ -f "$APP" ] && [ -f "$RUN" ] || { echo "FAIL: a source or run.sh is missing" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: the checks need perl, and there is none" >&2; exit 2; }

# pcheck <label> <file> <perl-regex> : the file (read whole, comments kept) must match.
pcheck() {
  local out
  out=$(perl -0ne 'exit(/'"$3"'/s ? 0 : 1)' "$2" 2>&1) && return 0
  echo "  CHECK $1" >&2; return 1
}

# suite <StoreService.java> <INowhereStore.aidl> <StoreActivity.java> -> 0 pass, 1 a check or case failed, 2/3 broken run.
suite() {
  local svc="$1" aidl="$2" app="$3" decls rc body
  # S1: the AIDL's LAST method is materializeOwn (NWP-20261119-19), and refreshIndex is declared once, directly before
  # it, after getApp.
  decls=$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$aidl" | grep -E '^\s*\S.*\(.*\);\s*$')
  [ "$(printf '%s\n' "$decls" | tail -n 1 | tr -d ' ')" = "StringmaterializeOwn(Stringpkg);" ] || { echo "  CHECK AIDL: materializeOwn is not the last method" >&2; return 1; }
  [ "$(printf '%s\n' "$decls" | tail -n 2 | head -n 1 | tr -d ' ')" = "StringrefreshIndex();" ] || { echo "  CHECK AIDL: refreshIndex is not directly before materializeOwn" >&2; return 1; }
  [ "$(printf '%s\n' "$decls" | grep -c 'refreshIndex')" = 1 ] || { echo "  CHECK AIDL: refreshIndex declared other than once" >&2; return 1; }
  [ "$(printf '%s\n' "$decls" | grep -c 'materializeOwn')" = 1 ] || { echo "  CHECK AIDL: materializeOwn declared other than once" >&2; return 1; }
  printf '%s\n' "$decls" | grep -q 'String getApp(' || { echo "  CHECK AIDL: getApp is gone" >&2; return 1; }
  # S2: refreshIndex = caller check, gate (SKIPPED), then REFRESH-INDEX -- in that order, REFRESH-INDEX sent once.
  pcheck "StoreService: REFRESH_INDEX_CAP_MS is 90000" "$svc" 'REFRESH_INDEX_CAP_MS = 90000;' || return 1
  pcheck "StoreService: refreshIndex order caller -> gate -> REFRESH-INDEX" "$svc" \
    'public String refreshIndex\(\) \{\s*if \(!callerIsStorefront\(\)\) return "ERR-CALLER";.*?indexRefreshAllowed\(.*?return "SKIPPED";.*?line\("REFRESH-INDEX\\n", REFRESH_INDEX_CAP_MS\)' || return 1
  body=$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$svc")
  [ "$(printf '%s' "$body" | grep -c 'REFRESH-INDEX')" = 1 ] || { echo "  CHECK StoreService: REFRESH-INDEX is sent other than once" >&2; return 1; }
  # S3: StoreActivity asks off the main thread, catching Throwable, from onServiceConnected.
  pcheck "StoreActivity: refreshIndex on its own thread inside try/catch Throwable" "$app" \
    'new Thread\(\(\) -> \{\s*try \{ s\.refreshIndex\(\); \} catch \(Throwable ignore\) \{\}\s*\}, "napps-index"\)\.start\(\);' || return 1
  [ "$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$app" | grep -c '\.refreshIndex()')" = 1 ] || { echo "  CHECK StoreActivity: refreshIndex called other than once" >&2; return 1; }
  pcheck "StoreActivity: onServiceConnected calls refreshIndexOnce" "$app" \
    'onServiceConnected\(.*?bound = true;\s*refreshIndexOnce\(\);' || return 1
  bash "$RUN" "$svc"; rc=$?
  return "$rc"
}

echo "== $SVC + $AIDL + $APP"
suite "$SVC" "$AIDL" "$APP" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: a mutant that is inert or does not compile proves nothing)"
mut() { # mut <label> <svc|aidl|app> <perl-expr>
  local d m rc src
  d=$(mktemp -d -p "$W") || return 1
  cp "$SVC" "$d/StoreService.java"; cp "$AIDL" "$d/INowhereStore.aidl"; cp "$APP" "$d/StoreActivity.java"
  case "$2" in svc) m="$d/StoreService.java" ;; aidl) m="$d/INowhereStore.aidl" ;; app) m="$d/StoreActivity.java" ;;
    *) echo "  ERROR     $1 -- bad target $2"; rm -rf "$d"; return 1 ;; esac
  cp "$m" "$m.orig"
  if ! perl -0pi -e "$3" "$m"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$m.orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rm -f "$m.orig"
  suite "$d/StoreService.java" "$d/INowhereStore.aidl" "$d/StoreActivity.java" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "I1 metered ignored" svc 's/if \(!metered\) return true;/if (true) return true;/' || fails=$((fails+1))
mut "I2 a missing reply is allowed" svc 's/prefetchMeteredReply != null && /prefetchMeteredReply == null || /' || fails=$((fails+1))
mut "I3 the method inserted before getApp" aidl 's/(\n\s*\/\*\*[^\n]*REFRESH-INDEX.*?String refreshIndex\(\);\n)//s; $x=$1; s/(\n\s*String getApp\(String pkg, String label\);)/$x$1/' || fails=$((fails+1))
mut "I4 the caller check removed" svc 's/(public String refreshIndex\(\) \{)\s*if \(!callerIsStorefront\(\)\) return "ERR-CALLER";/$1/' || fails=$((fails+1))
mut "I5 REFRESH-INDEX sent before the gate" svc 's/(boolean metered = activeNetworkMetered\(\);)/String early = line("REFRESH-INDEX\\n", REFRESH_INDEX_CAP_MS); $1/' || fails=$((fails+1))
mut "I6 the nApps catch narrowed" app 's/catch \(Throwable ignore\) \{\}(\s*\}, "napps-index")/catch (android.os.RemoteException ignore) {}$1/' || fails=$((fails+1))
mut "I7 materializeOwn inserted before refreshIndex" aidl 's/(\n\s*\/\*\*[^\n]*MATERIALIZE-OWN.*?String materializeOwn\(String pkg\);\n)/\n/s; $x=$1; s/(\n\s*\/\*\*[^\n]*REFRESH-INDEX)/$x$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
