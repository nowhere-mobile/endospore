#!/usr/bin/env bash
# test-plan-gate-fmt.sh [--mutate] -- the over-plan gate and the two byte formatters, RUN rather than grepped.
#
# WHAT IS UNDER TEST. Three pure members of the chooser, none of which touch Android:
#   - StoreInstaller.overPlanLine parses the agent's GET-ENTITLEMENT reply (StoreService asks it before a
#     store install) and says whether the profile is over plan. It FAILS OPEN: anything it cannot parse --
#     null, an ERR reply, a missing or non-numeric field, no coverage at all -- reads as NOT over plan, so a
#     garbled line never refuses an install.
#   - UnarchiveService.fmtB and ProfileActivity.fmtBytes turn a byte count into one human figure. fmtB's own
#     comment says it MIRRORS fmtBytes and is duplicated only to keep the service free-standing. Nothing but
#     this suite holds the two copies together, so it checks that they return the SAME string on every
#     boundary value, plus the exact figures their comments promise.
#
# ⚠ THESE ARE RUN, NOT PINNED, for the reason test-ingest-key.sh gives: a source grep cannot tell you what a
# function DOES. The members are EXTRACTED verbatim from the shipped sources (brace-matched from each
# signature, `private` stripped), wrapped in one `final class Lifted`, and run under a real JVM.
#
# It needs a JDK, and it FAILS when there is none (exit 2): a Java suite that skips without one would read
# green on a runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-plan-gate-fmt.sh              # the truth table and the agreement check
#   bash test-plan-gate-fmt.sh --mutate     # ... plus mutations that must each CONVICT the suite
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/src/com/nowhere/chooser"
STORE="$SRC/StoreInstaller.java"
UNARCH="$SRC/UnarchiveService.java"
PROFILE="$SRC/ProfileActivity.java"
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
  echo "test-plan-gate-fmt: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract() { # extract <file> <signature-fragment> -- the member, brace-matched, with `private ` stripped
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
            print(src[i:k+1].replace('private ', '', 1)); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

build() { # build <StoreInstaller.java> <UnarchiveService.java> <ProfileActivity.java> -> compiled into $WORK
  rm -f "$WORK/PlanGateFmt.java" "$WORK"/*.class
  {
    echo 'final class Lifted {'
    extract "$1" 'static boolean overPlanLine('       || return 3
    extract "$2" 'private static String fmtB(long b)' || return 3
    extract "$3" 'private static String fmtBytes(long b)' || return 3
    echo '}'
    cat <<'JAVA'
public class PlanGateFmt {
  static int fails = 0;
  static void is(String what, boolean got, boolean want) {
    if (got == want) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": got " + got + ", want " + want); fails++; }
  }
  static void eq(String what, String got, String want) {
    if (want.equals(got)) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": got \"" + got + "\", want \"" + want + "\""); fails++; }
  }
  static void over(String line, boolean want) {
    is("overPlanLine(" + (line == null ? "null" : "\"" + line + "\"") + ") == " + want, Lifted.overPlanLine(line), want);
  }
  public static void main(String[] a) {
    System.out.println("-- overPlanLine: over only when used > covered > 0; anything unparseable fails OPEN");
    over(null, false);
    over("ERR timeout", false);
    over("ERR used=11 covered=10", false);               // an ERR reply carrying the fields is still an ERR
    over("OK used=5 covered=10", false);
    over("OK used=11 covered=10", true);
    over("OK covered=10 used=11", true);                 // field order is free
    over("OK used=10 covered=10", false);                // at the line is not over it
    over("OK used=11 covered=0", false);                 // no coverage at all fails open
    over("OK used=11", false);                           // covered missing
    over("OK covered=10", false);                        // used missing
    over("OK used=x covered=10", false);                 // non-numeric
    over("OK used=11 covered=10 extra=junk tail", true); // unknown tokens are ignored
    over("OK used=11 covered=10  ", true);               // trailing whitespace is tolerated
    over(" OK used=11 covered=10", false);               // leading is NOT: startsWith("OK") runs before trim()
    over("", false);

    System.out.println("-- fmtB (UnarchiveService) and fmtBytes (ProfileActivity) agree on every boundary");
    final long K = 1024L, M = K * K, G = M * K, T = G * K;
    final long mb4_2 = (long) (4.2 * M), gb1_3 = (long) (1.3 * G), tb5_5 = (long) (5.5 * T);
    long[] bs = { -5, 0, 1, 1023, 1024, 862 * K, M - 1, M, mb4_2, 10 * M - 1, 10 * M, 145 * M,
                  G - 1, G, gb1_3, tb5_5, Long.MAX_VALUE };
    for (long b : bs) eq("fmtB(" + b + ") == fmtBytes(" + b + ")", Lifted.fmtB(b), Lifted.fmtBytes(b));

    System.out.println("-- the figures the comments promise (both copies)");
    // 0 B -> "1 KB": below 1 MiB the figure is max(1, b / 1024) KB, so nothing ever reads "0 KB".
    // 862 KiB -> 862 KB. 4.2 MiB = 4404019 B -> 4.19999.. MB -> "%.1f" -> "4.2 MB".
    // 145 MiB -> round(145.0) -> "145 MB". 1.3 GiB = 1395864371 B -> 1.29999.. GB -> "%.1f" -> "1.3 GB".
    String[][] want = { { "0", "1 KB" }, { String.valueOf(862 * K), "862 KB" }, { String.valueOf(mb4_2), "4.2 MB" },
                        { String.valueOf(145 * M), "145 MB" }, { String.valueOf(gb1_3), "1.3 GB" },
                        // the unit is picked from the ROUNDED figure: nothing reads "10.0 MB" or "1024 MB"
                        { String.valueOf(10 * M - 1), "10 MB" }, { String.valueOf(G - 1), "1.0 GB" },
                        { String.valueOf(10 * M), "10 MB" }, { String.valueOf(G), "1.0 GB" },
                        { String.valueOf((long) (9.94 * M)), "9.9 MB" }, { String.valueOf(1023 * M), "1023 MB" } };
    for (String[] w : want) {
      long b = Long.parseLong(w[0]);
      eq("fmtBytes(" + b + ") == " + w[1], Lifted.fmtBytes(b), w[1]);
      eq("fmtB(" + b + ") == " + w[1], Lifted.fmtB(b), w[1]);
    }

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$WORK/PlanGateFmt.java" || return 3
  "$JAVAC" -nowarn -d "$WORK" "$WORK/PlanGateFmt.java" 2>"$WORK/javac.err" || return 4
}

suite() { # suite <store> <unarch> <profile> [quiet] -> 0 pass, 1 fail, 3 extraction failed, 4 compile failed
  build "$1" "$2" "$3"; local rc=$?
  if [ "$rc" = 3 ]; then [ "${4:-}" = quiet ] || echo "EXTRACTION FAILED"; return 3; fi
  if [ "$rc" != 0 ]; then [ "${4:-}" = quiet ] || { echo "compile failed:"; head -5 "$WORK/javac.err"; }; return 4; fi
  if [ "${4:-}" = quiet ]; then "$JAVA" -cp "$WORK" PlanGateFmt >/dev/null 2>&1; else "$JAVA" -cp "$WORK" PlanGateFmt; fi
}

suite "$STORE" "$UNARCH" "$PROFILE"; RC=$?
[ "$RC" -ge 3 ] && exit 2
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <which: store|unarch|profile> <sed script>
  local s="$STORE" u="$UNARCH" p="$PROFILE" orig m="$WORK/mut-$2.java"
  case "$2" in store) orig=$STORE; s=$m ;; unarch) orig=$UNARCH; u=$m ;; profile) orig=$PROFILE; p=$m ;; esac
  sed "$3" "$orig" > "$m"
  # A sed that matched nothing leaves the source as it was, and that "mutant" would survive for the wrong reason.
  if cmp -s "$orig" "$m"; then printf '  ⚠ NOT APPLIED %s (the pattern no longer matches)\n' "$1"; MRC=1; return; fi
  suite "$s" "$u" "$p" quiet; local rc=$?
  case "$rc" in
    0) printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1 ;;
    1) printf '  convicted   %s\n' "$1" ;;
    *) printf '  ⚠ DID NOT BUILD %s\n' "$1"; MRC=1 ;;
  esac
}
OPL='/static boolean overPlanLine(/,/^    }/'
mutant "M1 over plan at the line (used >= covered)" store "$OPL s/used > covered/used >= covered/"
mutant "M2 no-coverage guard dropped"               store "$OPL s/covered > 0 && //"
mutant "M3 fmtB alone drifts (mb < 100)"            unarch  '/private static String fmtB(long b)/,/^    }/ s/Math.round(mb \* 10) < 100/Math.round(mb * 10) < 1000/'
mutant "M4 fmtBytes shows two GB decimals"          profile '/private static String fmtBytes(long b)/,/^    }/ s/%\.1f GB/%.2f GB/'
mutant "M6 fmtBytes picks MB decimals from the raw value" profile '/private static String fmtBytes(long b)/,/^    }/ s/Math.round(mb \* 10) < 100/mb < 10/'
mutant "M7 fmtB picks MB from the raw value (1024 MB)" unarch '/private static String fmtB(long b)/,/^    }/ s/Math.round(mb) < 1024/mb < 1024/'
mutant "M5 the OK-prefix check removed"             store "$OPL s/ || !entitlement.startsWith(\"OK\")//"

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
