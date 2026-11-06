#!/usr/bin/env bash
# test-store-compat.sh [--mutate] -- the nApps store labels what this phone cannot run and says what the search cut
# (NWP-20261013-42). The daemon's search reply carries minSdk / nativecode per entry and `generated` (unix seconds) /
# `truncated` per reply; StoreActivity used to render none of them, so Get on an app needing a newer Android or
# another ABI ended in a generic installer error and a 50-capped list looked complete.
#
# StoreActivity cannot be compiled off the build host (Android classes), so its pure members, fenced by
# `BEGIN/END store-compat`, are lifted verbatim into a harness and run under javac/java.
#
#   bash test-store-compat.sh            # the invariants
#   bash test-store-compat.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(cd "$(dirname "$0")" && pwd)"
SRC="$D/src/com/nowhere/napps/StoreActivity.java"
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 2; }
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
# FAILS without a JDK, never skips (same rule as the other javac suites; the CI runner is the build VM).
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
    JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
    echo "FAIL: no javac on PATH or at $HOST_JDK; this suite does not skip" >&2; exit 2
fi
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

LIFTED="$(sed -n '/BEGIN store-compat/,/END store-compat/p' "$SRC")"
grep -q 'static String incompatReason' <<<"$LIFTED" || { echo "FAIL  no store-compat block with incompatReason in StoreActivity" >&2; exit 1; }

cat >"$W/T.java" <<'JAVA'
public class T {
    static int fails = 0;
    static void eq(String what, Object want, Object got) {
        boolean ok = want == null ? got == null : want.equals(got);
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what + (ok ? "" : "  want=" + want + " got=" + got));
        if (!ok) fails++;
    }
    public static void main(String[] a) {
        String[] abis = {"arm64-v8a", "armeabi-v7a"};
        eq("minSdk above device", "Needs a newer Android", S.incompatReason(35, null, 34, abis));
        eq("minSdk equal device", null, S.incompatReason(34, null, 34, abis));
        eq("minSdk unset", null, S.incompatReason(0, null, 34, abis));
        eq("ABI match", null, S.incompatReason(21, new String[]{"x86", "arm64-v8a"}, 34, abis));
        eq("ABI mismatch", "Not built for this phone", S.incompatReason(21, new String[]{"x86", "x86_64"}, 34, abis));
        eq("ABI empty list", null, S.incompatReason(21, new String[0], 34, abis));
        eq("minSdk wins over ABI", "Needs a newer Android", S.incompatReason(40, new String[]{"x86"}, 34, abis));
        eq("truncated + date", "Showing the top 50 matches. Refine your search to see more.\nCatalog from 2026-10-13",
                S.searchNote(true, 1791849600L));
        eq("date only", "Catalog from 2026-10-13", S.searchNote(false, 1791849600L));
        eq("truncated only (generated 0)", "Showing the top 50 matches. Refine your search to see more.", S.searchNote(true, 0));
        eq("neither", "", S.searchNote(false, 0));
        eq("date is seconds, UTC", "Catalog from 1970-01-02", S.searchNote(false, 86400L));
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA

# run_suite <lifted-source>: compile + run against it; exit status is the suite's.
run_suite() {
    local dir="$W/r.$RANDOM"; mkdir -p "$dir"
    { echo 'class S {'; printf '%s\n' "$1"; echo '}'; } >"$dir/S.java"
    cp "$W/T.java" "$dir/T.java"
    "$JAVAC" -d "$dir" "$dir/S.java" "$dir/T.java" 2>"$dir/err" || { cat "$dir/err" >&2; return 2; }
    "$JAVA" -cp "$dir" T
}

run_suite "$LIFTED"; rc=$?
[ $rc -eq 0 ] || { echo "FAIL  suite against the real block"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "-- mutants"
bad=0
mutant() { # <name> <sed-expr>
    local m; m="$(sed "$2" <<<"$LIFTED")"
    if [ "$m" = "$LIFTED" ]; then echo "  FAIL  mutant '$1' did not apply"; bad=1; return; fi
    if run_suite "$m" >/dev/null 2>&1; then echo "  FAIL  mutant '$1' SURVIVED"; bad=1; else echo "  ok    mutant '$1' convicted"; fi
}
mutant "minSdk comparison flipped" 's/minSdk > sdkInt/minSdk < sdkInt/'
mutant "minSdk off by one" 's/minSdk > sdkInt/minSdk >= sdkInt/'
mutant "ABI check ignored" 's/return "Not built for this phone"/return null/'
mutant "truncated line never shown" 's/if (truncated) sb/if (false) sb/'
mutant "generated treated as milliseconds" 's/generatedSecs \* 1000L/generatedSecs/'
exit $bad
