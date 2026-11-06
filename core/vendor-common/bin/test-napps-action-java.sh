#!/usr/bin/env bash
# test-napps-action-java.sh [--mutate] -- nApps offers "Download" for an On-demand app the session already holds, and
# the tap materialises the session's own sealed copy, under javac (NWP-20261119-19).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, h49 #1 (2026-10-31): button "Download" instead of "Get", grey line
# "In your apps · not on this phone yet", then "Downloading your copy of <App>…"; a newer catalog version from the same
# publisher keeps "Update" and the grey line. Q051 (2026-10-20): the tap starts the materialise of the sealed copy
# through a new StoreService call, so the group materialise brings its Play dependencies. Before this slice
# StoreActivity painted "Get" whenever getPackageInfo(pkg, 0) failed, which an archived placeholder does, and the tap
# called getApp, whose FETCH-APP downloads the catalog APK.
#
# The CASES compile core/napps/src/com/nowhere/napps/NappsAction.java ALONE with
# core/napps/tests/napps-action/NappsActionCases.java: every state and its grey line, and the h49 #1 strings against
# the text this suite extracts from docs/product-decisions.md. The GATE cases lift StoreService's materialize-own fence
# into a class OwnGate and run core/napps/tests/napps-action/OwnGateCases.java. The PINS check what neither can see:
# onGet dispatches by state (ADDED inert, DOWNLOAD to downloadOwn before any getApp, no inert test by label text);
# downloadOwn calls materializeOwn and never getApp; StoreActivity and StoreService read the archived package through
# PackageInfoFlags.of(...MATCH_ARCHIVED_PACKAGES) (the long flag; the int overload drops it); StoreService.materializeOwn
# checks the caller first, refuses through mayMaterializeOwn before it starts UnarchiveService, and starts it with
# EXTRA_PKG and no unarchive id.
#
# Exit codes: 0 pass, 1 a case or a pin failed (or a mutant survived), 2 a source is missing, the decision text does
# not match, or there is no javac/perl.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-napps-action-java.sh            # the cases, the gate cases and the pins
#   bash test-napps-action-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
NA="$root/core/napps/src/com/nowhere/napps/NappsAction.java"
SA="$root/core/napps/src/com/nowhere/napps/StoreActivity.java"
SVC="$root/core/chooser/src/com/nowhere/chooser/StoreService.java"
DOC="$root/docs/product-decisions.md"
CASES="$root/core/napps/tests/napps-action/NappsActionCases.java"
GCASES="$root/core/napps/tests/napps-action/OwnGateCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
for f in "$NA" "$SA" "$SVC" "$DOC" "$CASES" "$GCASES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# The three h49 #1 strings, from the decision record itself: the button, the grey line, the status.
H49="$W/h49.txt"
perl -0ne 'if (/nApps: button \*"([^"]+)"\* instead of "Get", grey line \*"([^"]+)"\*, then \*"([^"]+)"\*/) { print "$1\n$2\n$3\n"; exit 0 } exit 1' \
  "$DOC" > "$H49" || { echo "FAIL: the h49 #1 nApps sentence is not in $DOC in the form this suite reads" >&2; exit 2; }

# strip <file> -> the file without its /* */ and // comments
strip() { perl -0pe 's{/\*.*?\*/}{}gs; s{(?<![:"])//[^\n]*}{}g' "$1"; }

# member <file> <signature-regex> -> the member, comments stripped, from its signature to the brace that closes it
member() {
  strip "$1" | SIG="$2" perl -0ne '
    if (/$ENV{SIG}/g) {
      my $start = $-[0]; my $i = pos(); my $d = 0; my $seen = 0;
      for (; $i < length($_); $i++) {
        my $c = substr($_, $i, 1);
        if ($c eq "{") { $d++; $seen = 1 } elsif ($c eq "}") { $d--; }
        last if $seen && $d == 0;
      }
      print substr($_, $start, $i - $start + 1); exit 0;
    }
    exit 1'
}

# pin <label> <text> <perl-regex> : the text must match
pin() {
  if printf '%s' "$2" | perl -0ne 'exit(/'"$3"'/s ? 0 : 1)'; then return 0; fi
  echo "  PIN  $1" >&2; return 1
}
# nopin <label> <text> <perl-regex> : the text must NOT match
nopin() {
  if printf '%s' "$2" | perl -0ne 'exit(/'"$3"'/s ? 0 : 1)'; then echo "  PIN  $1" >&2; return 1; fi
  return 0
}

# suite <NappsAction.java> <StoreActivity.java> <StoreService.java> -> 0 pass, 1 a case or pin failed, 2 broken run
suite() {
  local na="$1" sa="$2" svc="$3" d out rc=0 sat ong dow arc sv mo ah
  d=$(mktemp -d -p "$W") || return 2

  # C: NappsAction alone, with its cases.
  mkdir -p "$d/c"
  if "$JAVAC" -nowarn -encoding UTF-8 -d "$d/c" "$na" "$CASES" > "$d/c.log" 2>&1; then
    if out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$d/c" com.nowhere.napps.NappsActionCases "$H49" 2>&1); then
      printf '%s\n' "$out" | tail -n 1
    else
      printf '%s\n' "$out" >&2; rc=1
    fi
  else
    cat "$d/c.log" >&2; echo "  CASES: NappsAction does not compile alone" >&2; rc=1
  fi

  # G: the materialize-own fence, lifted into OwnGate.
  mkdir -p "$d/g"
  if ! perl -0ne 'if (m{// BEGIN materialize-own[^\n]*\n(.*?)// END materialize-own}s) { print "final class OwnGate {\n$1}\n"; exit 0 } exit 1' \
      "$svc" > "$d/g/OwnGate.java"; then
    echo "  GATE: no materialize-own fence in StoreService" >&2; rc=1
  elif "$JAVAC" -nowarn -encoding UTF-8 -d "$d/g" "$d/g/OwnGate.java" "$GCASES" > "$d/g.log" 2>&1; then
    if out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$d/g" OwnGateCases 2>&1); then
      printf '%s\n' "$out" | tail -n 1
    else
      printf '%s\n' "$out" >&2; rc=1
    fi
  else
    cat "$d/g.log" >&2; echo "  GATE: the materialize-own fence does not compile" >&2; rc=1
  fi
  rm -rf "$d"

  # P: source pins.
  sat=$(strip "$sa")
  ong=$(member "$sa" 'private void onGet\(') || { echo "  PIN  StoreActivity: no onGet" >&2; return 1; }
  dow=$(member "$sa" 'private void downloadOwn\(') || { echo "  PIN  StoreActivity: no downloadOwn" >&2; return 1; }
  arc=$(member "$sa" 'PackageInfo archivedInfo\(') || { echo "  PIN  StoreActivity: no archivedInfo" >&2; return 1; }
  pin "P1 onGet: DOWNLOAD goes to downloadOwn and returns, before any getApp" "$ong" \
    'if \(st == NappsAction\.State\.DOWNLOAD\) \{\s*downloadOwn\([^;]*\);\s*return;\s*\}.*store\.getApp\(' || rc=1
  pin "P1 onGet: the state is read at the tap through stateFor" "$ong" \
    'NappsAction\.State st = stateFor\(pkg, catalogVc, catalogCert, null\);.*?if \(st == NappsAction\.State\.ADDED\) return;' || rc=1
  pin "P2 downloadOwn calls store.materializeOwn(pkg)" "$dow" 'store\.materializeOwn\(pkg\)' || rc=1
  nopin "P2 downloadOwn never calls getApp" "$dow" 'getApp\(' || rc=1
  [ "$(printf '%s' "$sat" | grep -c 'materializeOwn(')" = 1 ] || { echo "  PIN  P2 StoreActivity calls materializeOwn other than once" >&2; rc=1; }
  nopin "P3 no inert test by label text" "$sat" 'contentEquals\(' || rc=1
  pin "P3 onGet: ADDED is inert, before any getApp" "$ong" 'if \(st == NappsAction\.State\.ADDED\) return;.*store\.getApp\(' || rc=1
  pin "P4 downloadOwn shows the h49 status" "$dow" 'setStatus\(NappsAction\.downloadingStatus\(label\)\);.*materializeOwn' || rc=1
  pin "P5 archivedInfo reads through PackageInfoFlags.of(...MATCH_ARCHIVED_PACKAGES)" "$arc" \
    'getPackageInfo\(pkg, [\w.]*PackageInfoFlags\.of\(\s*[\w.]*MATCH_ARCHIVED_PACKAGES' || rc=1
  [ "$(printf '%s' "$sat" | grep -c 'MATCH_ARCHIVED_PACKAGES')" = 1 ] || { echo "  PIN  P5 StoreActivity names MATCH_ARCHIVED_PACKAGES other than once (in archivedInfo)" >&2; rc=1; }
  pin "P5 stateFor reads archivedInfo" "$sat" 'stateFor\([^)]*\) \{.*?archivedInfo\(pkg\)' || rc=1

  sv=$(strip "$svc")
  mo=$(member "$svc" 'public String materializeOwn\(String pkg\)') || { echo "  PIN  StoreService: no materializeOwn" >&2; return 1; }
  ah=$(member "$svc" 'private boolean archivedHere\(String pkg\)') || { echo "  PIN  StoreService: no archivedHere" >&2; return 1; }
  pin "P6 materializeOwn starts with the caller check" "$mo" \
    '^public String materializeOwn\(String pkg\) \{\s*if \(!callerIsStorefront\(\)\) return "ERR-CALLER";' || rc=1
  pin "P7 materializeOwn refuses through mayMaterializeOwn before it starts UnarchiveService" "$mo" \
    '!mayMaterializeOwn\(UnarchiveService\.hasInstalledCode\(StoreService\.this, pkg\), archivedHere\(pkg\),\s*ProfileActivity\.deferredKeepSet\(StoreService\.this\)\.contains\(pkg\)\)\)\s*return "ERR-NOTARCHIVED";.*startForegroundService\(new Intent\(StoreService\.this, UnarchiveService\.class\)\s*\.putExtra\(UnarchiveService\.EXTRA_PKG, pkg\)\);\s*return "OK";' || rc=1
  nopin "P7 materializeOwn starts UnarchiveService with no unarchive id" "$mo" 'EXTRA_ID' || rc=1
  pin "P8 archivedHere reads through PackageInfoFlags.of(...MATCH_ARCHIVED_PACKAGES)" "$ah" \
    'getPackageInfo\(pkg, [\w.]*PackageInfoFlags\.of\(\s*[\w.]*MATCH_ARCHIVED_PACKAGES\)\) != null;' || rc=1
  [ "$(printf '%s' "$sv" | grep -c 'MATCH_ARCHIVED_PACKAGES')" = 1 ] || { echo "  PIN  P8 StoreService names MATCH_ARCHIVED_PACKAGES other than once (in archivedHere)" >&2; rc=1; }
  return "$rc"
}

echo "== $NA + $SA + $SVC"
suite "$NA" "$SA" "$SVC"; rc=$?
case "$rc" in 0) ;; 1) echo "FAILED"; exit 1 ;; *) echo "BROKEN (rc=$rc)"; exit 2 ;; esac
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: a mutant that is inert or does not apply proves nothing)"
mut() { # mut <label> <na|sa|svc> <perl-expr>
  local d m rc
  d=$(mktemp -d -p "$W") || return 1
  cp "$NA" "$d/NappsAction.java"; cp "$SA" "$d/StoreActivity.java"; cp "$SVC" "$d/StoreService.java"
  case "$2" in na) m="$d/NappsAction.java" ;; sa) m="$d/StoreActivity.java" ;; svc) m="$d/StoreService.java" ;;
    *) echo "  ERROR     $1 -- bad target $2"; rm -rf "$d"; return 1 ;; esac
  cp "$m" "$m.orig"
  if ! perl -0pi -e "$3" "$m"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$m.orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rm -f "$m.orig"
  suite "$d/NappsAction.java" "$d/StoreActivity.java" "$d/StoreService.java" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- rc=$rc"; return 1 ;;
  esac
}
fails=0
mut "M1 an archived app read as Get" na 's/(if \(archivedHere\) return .*?State\.UPDATE : )State\.DOWNLOAD;/${1}State.GET;/' || fails=$((fails+1))
mut "M2 Update of an archived app without sameSigner" na 's/haveVc > 0 && catalogVc > haveVc && sameSigner \?/haveVc > 0 \&\& catalogVc > haveVc ?/' || fails=$((fails+1))
mut "M3 Update of an installed app without sameSigner" na 's/catalogVc > 0 && catalogVc > haveVc && sameSigner \?/catalogVc > 0 \&\& catalogVc > haveVc ?/' || fails=$((fails+1))
mut "M4 the inert check by label text" sa 's/if \(st == NappsAction\.State\.ADDED\) return;/if ("Added".contentEquals(action.getText())) return;/' || fails=$((fails+1))
mut "M5 Download falls through to getApp" sa 's/if \(st == NappsAction\.State\.DOWNLOAD\) \{.*?downloadOwn\([^;]*\);\s*return;\s*\}//s' || fails=$((fails+1))
mut "M6 downloadOwn asks for the catalog build" sa 's/store\.materializeOwn\(pkg\)/store.getApp(pkg, label)/' || fails=$((fails+1))
mut "M7 the gate does not refuse a package that is not archived" svc 's/return !hasCode && archivedHere && inKeepSet;/return true;/' || fails=$((fails+1))
mut "M8 materializeOwn does not refuse a package that is not archived" svc 's/(public String materializeOwn\(String pkg\) \{\s*if \(!callerIsStorefront\(\)\) return "ERR-CALLER";).*?return "ERR-NOTARCHIVED";/$1/s' || fails=$((fails+1))
mut "M9 materializeOwn's caller check removed" svc 's/(public String materializeOwn\(String pkg\) \{)\s*if \(!callerIsStorefront\(\)\) return "ERR-CALLER";/$1/' || fails=$((fails+1))
mut "M10 materializeOwn's caller check after the start" svc 's/(public String materializeOwn\(String pkg\) \{)\s*(if \(!callerIsStorefront\(\)\) return "ERR-CALLER";)(.*?return "OK";)/$1$3\n$2/s' || fails=$((fails+1))
mut "M11 nApps's archived read through the int overload" sa 's/getPackageInfo\(pkg, android\.content\.pm\.PackageManager\.PackageInfoFlags\.of\(/getPackageInfo(pkg, (int) (/' || fails=$((fails+1))
mut "M12 the chooser's archived read through the int overload" svc 's/getPackageInfo\(pkg, android\.content\.pm\.PackageManager\.PackageInfoFlags\.of\(/getPackageInfo(pkg, (int) (/' || fails=$((fails+1))
mut "M13 the grey line dropped for an archived Update" na 's/\s*if \(s == State\.UPDATE && archivedHere\) return GREY;//' || fails=$((fails+1))
mut "M14 the h49 status changed" na 's/"Downloading your copy of "/"Downloading "/' || fails=$((fails+1))
mut "M15 the start carries an unarchive id" svc 's/\.putExtra\(UnarchiveService\.EXTRA_PKG, pkg\)\);/.putExtra(UnarchiveService.EXTRA_PKG, pkg).putExtra(UnarchiveService.EXTRA_ID, 0));/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
