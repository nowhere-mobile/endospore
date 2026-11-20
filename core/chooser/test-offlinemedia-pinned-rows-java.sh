#!/usr/bin/env bash
# test-offlinemedia-pinned-rows-java.sh [--mutate] [<OfflineMediaRows.java> <ProfileActivity.java>] -- Offline media
# keeps a row for a segment the profile keeps Essential, though LIST-MEDIA-APPS no longer lists it (NWP-20261203-26).
#
# The daemon lists only segments that still have DEFERRED entries. Once a pinned folder's files have all materialised,
# its row left the screen while nowhere-pins still held it, so the user could not set it back (finding M, S7 on lynx).
# (a) OfflineMediaRows.keptWithoutListing is compiled and EXECUTED. (b) Source pins on ProfileActivity:
#   P1 showOfflineMedia calls OfflineMediaRows.keptWithoutListing( with pins and overrides, after the reply loop and
#      before `if (rows == 0) {`;
#   P2 the loop over its result adds mediaAppRow(<seg>, -1, ...) and counts rows++ (else 'Nothing to manage here'
#      would also show);
#   P3 mediaAppRow draws the size TextView only when bytes >= 0;
#   P4 the loop over the kept segments puts nothing in `sizes` (the usage line counts listed bytes only).
#
#   bash test-offlinemedia-pinned-rows-java.sh            # cases + pins
#   bash test-offlinemedia-pinned-rows-java.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail

MUTATE=no; ARGS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) ARGS+=("$a") ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROWS="${ARGS[0]:-$HERE/src/com/nowhere/chooser/OfflineMediaRows.java}"
PA="${ARGS[1]:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"

command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1 || {
  echo "SKIP: no javac/java on PATH -- this suite RUNS keptWithoutListing." >&2; exit 3; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its source pins" >&2; exit 1; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# body <file> <signature>: the member from its signature line to its closing brace at the same indent.
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on = 1; match($0, /^ */); ind = RLENGTH }
    on { print; if ($0 ~ "^ {" ind "}\\}") exit }
  ' "$1"
}

# cases <OfflineMediaRows.java>: compile the class with a driver in its package and run the truth table.
cases() {
  local rows=$1 d out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  if [ ! -f "$rows" ]; then echo "  FAIL  (a) no such file: $rows"; return 1; fi
  cp "$rows" "$d/src/com/nowhere/chooser/OfflineMediaRows.java"
  cat > "$d/src/com/nowhere/chooser/OfflineMediaRowsT.java" <<'JAVA'
package com.nowhere.chooser;

import java.util.*;

public class OfflineMediaRowsT {
    static int fails = 0;
    static final String OWN = "com.nowhere.chooser";
    static Set<String> set(String... a) { return new LinkedHashSet<>(Arrays.asList(a)); }
    static Map<String,String> map(String... kv) {
        Map<String,String> m = new LinkedHashMap<>();
        for (int i = 0; i + 1 < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }
    static void eq(String what, List<String> got, String want) {
        if (!String.valueOf(got).equals(want)) { System.out.println("  FAIL  " + what + ": got " + got + ", want " + want); fails++; }
        else System.out.println("  ok    " + what);
    }
    public static void main(String[] a) {
        eq("C1 S7: a pinned folder absent from the listing keeps a row",
           OfflineMediaRows.keptWithoutListing(set("Download", "OsmAnd~", "DCIM"), set("Pictures"), map(), OWN), "[Pictures]");
        eq("C2 a pinned folder the daemon listed gets no second row",
           OfflineMediaRows.keptWithoutListing(set("Pictures"), set("Pictures"), map(), OWN), "[]");
        eq("C3 an essential override with no pin keeps a row",
           OfflineMediaRows.keptWithoutListing(set(), set(), map("Music", "essential"), OWN), "[Music]");
        eq("C4 a pin under a prefetch override is not Essential",
           OfflineMediaRows.keptWithoutListing(set(), set("Pictures"), map("Pictures", "prefetch"), OWN), "[]");
        eq("C5 a pin under an ondemand override is not Essential",
           OfflineMediaRows.keptWithoutListing(set(), set("Pictures"), map("Pictures", "ondemand"), OWN), "[]");
        eq("C6 the chooser's own segment never gets a row",
           OfflineMediaRows.keptWithoutListing(set(), set(OWN), map(OWN, "essential"), OWN), "[]");
        Set<String> blanks = new HashSet<>(Arrays.asList("", "  ", null));
        Map<String,String> blankTiers = new HashMap<>(); blankTiers.put("  ", "essential"); blankTiers.put(null, "essential");
        eq("C7 blank and null segments get no row",
           OfflineMediaRows.keptWithoutListing(set(), blanks, blankTiers, OWN), "[]");
        eq("C8 null listed, pins and overrides give none",
           OfflineMediaRows.keptWithoutListing(null, null, null, OWN), "[]");
        eq("C8b null listed still returns a pin",
           OfflineMediaRows.keptWithoutListing(null, set("Pictures"), null, OWN), "[Pictures]");
        eq("C9 rows come back sorted, not in pin order",
           OfflineMediaRows.keptWithoutListing(set(), set("Pictures", "Music"), map(), OWN), "[Music, Pictures]");
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA
  if ! javac -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/com/nowhere/chooser/OfflineMediaRows.java" \
       "$d/src/com/nowhere/chooser/OfflineMediaRowsT.java" > "$d/javac.err" 2>&1; then
    echo "  FAIL  (a) OfflineMediaRows does not compile:"; sed 's/^/        /' "$d/javac.err" | head -12; return 1
  fi
  out=$(java -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.OfflineMediaRowsT 2>&1); rc=$?
  echo "$out"
  [ "$rc" -eq 0 ]
}

# pins <ProfileActivity.java>: P1-P4. rc 1 = a pin failed, 2 = a member is missing.
pins() {
  local pa=$1 s m bad=0
  s=$(body "$pa" 'private void showOfflineMedia(')
  [ -n "$s" ] || { echo "  FAIL  no showOfflineMedia in $pa"; return 2; }
  m=$(body "$pa" 'private View mediaAppRow(')
  [ -n "$m" ] || { echo "  FAIL  no mediaAppRow in $pa"; return 2; }
  if B=$s perl -0e 'exit(($ENV{B} =~ /mediaAppRow\(app, bytes,.*?\brows\+\+;.*?OfflineMediaRows\.keptWithoutListing\(([^\n]*?)\)\) \{.*?if \(rows == 0\) \{/s
                         && ($a = $1) =~ /\bpins\b/ && $a =~ /\boverrides\b/) ? 0 : 1)'; then
    echo "  ok    P1 showOfflineMedia calls keptWithoutListing(.. pins, overrides ..) after the reply loop, before rows == 0"
  else echo "  FAIL  P1 no keptWithoutListing( with pins and overrides between the reply loop and 'if (rows == 0) {'"; bad=1; fi
  if B=$s perl -0e 'exit(($ENV{B} =~ /for \(String (\w+) : OfflineMediaRows\.keptWithoutListing\([^\n]*\)\) \{(.*?)\n\s*\}\n/s
                         && index($2, "mediaAppRow($1, -1,") >= 0 && $2 =~ /\brows\+\+;/) ? 0 : 1)'; then
    echo "  ok    P2 the kept loop adds mediaAppRow(<seg>, -1, ..) and counts rows++"
  else echo "  FAIL  P2 the loop over keptWithoutListing does not add mediaAppRow(<seg>, -1, ..) and rows++"; bad=1; fi
  if B=$m perl -0e 'exit(($ENV{B} =~ /if \(bytes >= 0\) \{[^}]*sz\.setText\(android\.text\.format\.Formatter\.formatShortFileSize\(this, bytes\)\);[^}]*top\.addView\(sz, /s) ? 0 : 1)'; then
    echo "  ok    P3 mediaAppRow draws the size TextView only when bytes >= 0"
  else echo "  FAIL  P3 mediaAppRow draws the size TextView without a bytes >= 0 guard"; bad=1; fi
  if B=$s perl -0e 'exit(($ENV{B} =~ /for \(String \w+ : OfflineMediaRows\.keptWithoutListing\([^\n]*\)\) \{(.*?)\n\s*\}\n/s
                         && index($1, "sizes.put") < 0) ? 0 : 1)'; then
    echo "  ok    P4 the kept loop puts nothing in sizes"
  else echo "  FAIL  P4 the kept loop is missing or puts a segment in sizes"; bad=1; fi
  return "$bad"
}

# check <OfflineMediaRows.java> <ProfileActivity.java>: rc 0 = all pass, 1 = convicted, 2 = a member is missing.
check() {
  local rows=$1 pa=$2 rc_a rc_b
  cases "$rows"; rc_a=$?
  pins "$pa"; rc_b=$?
  [ "$rc_b" -eq 2 ] && return 2
  [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]
}

check "$ROWS" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <rows|pa> <perl-expr>
  local d f rows pa out rc
  d=$(mktemp -d -p "$W"); rows=$ROWS; pa=$PA
  if [ "$2" = rows ]; then f="$d/OfflineMediaRows.java"; cp "$ROWS" "$f"; else f="$d/ProfileActivity.java"; cp "$PA" "$f"; fi
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if [ "$2" = rows ]; then
    if cmp -s "$ROWS" "$f"; then echo "  INERT     $1"; return 1; fi
    rows=$f
    if ! javac -J-Djava.io.tmpdir="$W" -d "$d" "$f" > "$d/javac.err" 2>&1; then echo "  BROKEN    $1 (does not compile)"; return 1; fi
  else
    if cmp -s "$PA" "$f"; then echo "  INERT     $1"; return 1; fi
    pa=$f
  fi
  out=$(check "$rows" "$pa" 2>&1); rc=$?
  if [ "$rc" -ne 1 ]; then
    if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; else echo "  BROKEN    $1 (rc=$rc)"; fi
    return 1
  fi
  echo "  convicted $1 -- by:$(printf '%s\n' "$out" | sed -n 's/^  FAIL  \([^:]*\).*/ \1/p' | tr '\n' ';')"
}
fails=0
mut "M1 the pin arm dropped (C1)" rows 's/"essential"\.equals\(o\) \|\| \(pinned\.contains\(seg\) && !"prefetch"\.equals\(o\) && !"ondemand"\.equals\(o\)\)/"essential".equals(o)/' || fails=$((fails+1))
mut "M2 the essential-override arm dropped (C3)" rows 's/"essential"\.equals\(o\) \|\| \(/(/' || fails=$((fails+1))
mut "M3 the listed exclusion dropped: duplicate rows (C2)" rows 's/ \|\| seen\.contains\(seg\)//' || fails=$((fails+1))
mut "M4 the ownPkg exclusion dropped (C6)" rows 's/ \|\| seg\.equals\(ownPkg\)//' || fails=$((fails+1))
mut "M5 the prefetch/ondemand precedence ignored (C4, C5)" rows 's/ && !"prefetch"\.equals\(o\) && !"ondemand"\.equals\(o\)//' || fails=$((fails+1))
mut "M6 the Collections.sort call removed (C9)" rows 's/\n[ \t]*java\.util\.Collections\.sort\(out\);//' || fails=$((fails+1))
mut "M7 the keptWithoutListing call removed from showOfflineMedia (P1)" pa 's/\n[ \t]*for \(String seg : OfflineMediaRows\.keptWithoutListing\([^\n]*\n[^\n]*\n[^\n]*\n[ \t]*\}//' || fails=$((fails+1))
mut "M8 rows++ removed from the kept loop (P2)" pa 's/(\n[ \t]*ll\.addView\(mediaAppRow\(seg, -1, 0, updateUsage\)\);)\n[ \t]*rows\+\+;/$1/' || fails=$((fails+1))
mut "M9 the bytes guard removed from mediaAppRow (P3)" pa 's/if \(bytes >= 0\) \{ \/\/ NWP-20261203-26[^\n]*/{/' || fails=$((fails+1))
mut "M10 the kept loop puts its segment in sizes (P4)" pa 's/(\n([ \t]*)ll\.addView\(mediaAppRow\(seg, -1, 0, updateUsage\)\);)/\n$2sizes.put(seg, 0L);$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
