#!/usr/bin/env bash
# test-app-claim-java.sh [--mutate] -- NWP-20261015-27: AppClaim's claim-record reader, receipt scoping and hold/release
# diff, the strict receipt reader (NWP-20261111-16) and the holder's name per hold (NWP-20261125-06), compiled and
# EXECUTED (core/chooser/tests/app-claim/run.sh says how).
#
# WHY THIS IS COMMITTED. AppClaim enforces the 2026-09-08 per-app concurrency decision by suspending packages another
# handset holds, and its header names the one failure it is built around: a hold that did not happen must never read as
# one. The reader carries the rule that cost NWP-20260911-01 a day -- an UNREADABLE record returns null and changes
# nothing, an EMPTY one releases every hold -- and the Go writer is tested while this reader was not.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE (a copy that no longer
# compiles convicts nothing and is reported).
#
#   bash test-app-claim-java.sh            # the cases
#   bash test-app-claim-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/app-claim/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-app-claim-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA
# Every temp of this suite lives inside $M (run.sh makes and removes its own).
M=$(mktemp -d) || exit 2
trap 'rm -rf "$M"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
bash "$RUN" "$CH"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  mutate(){ # mutate <label> <file under the chooser dir> <sed script>
    rm -rf "$M/c"; mkdir -p "$M/c/src/com/nowhere/chooser"
    cp "$CH"/src/com/nowhere/chooser/AppClaim.java "$M/c/src/com/nowhere/chooser/"
    local f="$M/c/$2"
    if ! sed -i "$3" "$f" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CH/$2"; then no "MUTATION INERT: $1"; return; fi
    bash "$RUN" "$M/c" >/dev/null 2>&1; local r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $1" ;;
    esac
  }
  A=src/com/nowhere/chooser/AppClaim.java
  mutate "an unreadable record (directory/EACCES) reads as empty, not null" $A '/static java.util.LinkedHashMap<String, String> readClaimsFile/,/^    }$/s/return null;/return new java.util.LinkedHashMap<>();/'
  mutate "claimedElsewhere of an unreadable record is no longer empty"       $A 's/return m == null ? java.util.Collections.<String>emptySet()/return m == null ? null/'
  mutate "the package '\/' check removed"                                    $A 's/if (!pkg.isEmpty() \&\& pkg.indexOf(.\/.) < 0) out.put/if (!pkg.isEmpty()) out.put/'
  mutate "the unit's trim removed"                                           $A 's/ln.substring(tab + 1, tab2)).trim();/ln.substring(tab + 1, tab2));/'
  mutate "M5 parseClaims keeps the third column in the unit"                   $A 's/String unit = (tab2 < 0 ? ln.substring(tab + 1) : ln.substring(tab + 1, tab2)).trim();/String unit = ln.substring(tab + 1).trim();/'
  mutate "M6 parseClaimNames ignores the third column"                         $A 's/if (!name.isEmpty() \&\& !control) out.put(pkg, name);//'
  mutate "M7 holdGroups always uses the fallback"                              $A 's/String where = n == null || n.isEmpty() ? fallback : n;/String where = fallback;/'
  mutate "the receipt's user check removed"                                  $A 's/matched = ln.equals(want); continue;/matched = true; continue;/'
  mutate "diff's release side inverted"                                      $A 's/for (String pkg : have) if (!want.containsKey(pkg)) toRelease.add(pkg);/for (String pkg : have) if (want.containsKey(pkg)) toRelease.add(pkg);/'
  mutate "applyFromFile diffs before it checks for an unreadable record"     $A '/Result applyFromFile(/,/^    }$/{s/if (want == null) {/if (false) {/}'
  mutate "M1 readReceiptFile returns empty for an existing unopenable receipt" $A '/static java.util.List<String> readReceiptFile(/,/^    }$/s/return null;/return new java.util.ArrayList<>();/'
  mutate "M2 parseReceipt(Reader) swallows a read error"                       $A '/static java.util.List<String> parseReceipt(java.io.Reader/,/^    }$/{s/^        while ((ln = r.readLine()) != null) {$/        try { while ((ln = r.readLine()) != null) {/;s/^        return out;$/        } catch (java.io.IOException e) {}\n        return out;/}'
  mutate "M3 applyFromFile diffs against an unreadable receipt"                $A '/Result applyFromFile(/,/^    }$/{s/if (have == null) {/if (false) {/}'
  mutate "M4 clearReceipt rewrites the receipt after an unreadable read"       $A '/static void clearReceipt(/,/^    }$/{s/if (held == null) {/if (false) {/}'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
