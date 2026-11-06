#!/usr/bin/env bash
# test-rotate-copy-java.sh [--mutate] -- the Change passphrase screen's reply copy, run under javac (NWP-20261108-13).
#
# WHY THIS IS COMMITTED. showChangePass renders the daemon's ROTATE reply through an equality chain; a code it does not
# know falls to "Your passphrase has not changed.", which is FALSE for an ERR-SESSION-like outcome where the change
# committed -- the user then keeps signing in with the old passphrase. The chooser had no test surface, and a prefix
# trap in this chain was once caught only by reading a diff. RotateCopy (pure, java.lang only) is compiled here with its
# cases; (a) every code handleRotate in core/agent/main.go can send must get a copy of its own and no code but the bare
# ERR may be a prefix of another; (b) showChangePass must render through RotateCopy and hold no "ERR- literal.
# NWP-20261115-04: (a) also reads the floor's fmt.Fprintf(conn, "WEAK %s\n", reason) as the code WEAK, and requires it.
# WEAK is the one code RotateCopy matches by prefix, because it carries its reason.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-rotate-copy-java.sh            # the cases, check (a), pin (b)
#   bash test-rotate-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RotateCopy.java"
SCREEN="$SRC/ProfileActivity.java"
AGENT="$root/core/agent/main.go"
CASES="$root/core/chooser/tests/rotate-copy/RotateCopyCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# build <RotateCopy.java> <dir> -> compiles RotateCopy with the cases alone into <dir>/out; 0 ok, 3 no compile.
build() {
  local src="$1" d="$2"
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RotateCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RotateCopyCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || return 3
}

# suite <RotateCopy.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RotateCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  build "$src" "$d" || { rm -rf "$d"; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RotateCopyCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# codes_check <main.go> <RotateCopy.java> -> check (a). 0 when every code handleRotate sends has its own copy and none
# but the bare ERR is a proper prefix of another.
codes_check() {
  local go="$1" src="$2" body live odd codes n a b d out line code same bad=0
  [ -f "$src" ] || { echo "  FAIL  RotateCopy.java does not exist" >&2; return 1; }
  body=$(awk '/^func handleRotate\(/ { on = 1 } on { print } on && /^}/ { exit }' "$go")
  live=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*//')
  codes=$(printf '%s\n' "$live" | grep -oE 'say\("[^"]*"\)|fmt\.Fprint\(conn, "[^"]*\\n"\)' \
    | sed -E 's/^say\("([^"]*)"\)$/\1/; s/^fmt\.Fprint\(conn, "([^"]*)\\n"\)$/\1/' | sort -u)
  # A reply this extraction cannot read as a literal is a failure, never a silent omission: every say(, fmt.Fprint(conn,,
  # fmt.Fprintf(conn, and conn.Write( line must be a plain "literal" form, or one of four named exceptions: say's own
  # definition (say := func(code string)), its fmt.Fprint(conn, code+"\n") write, fmt.Fprintf(conn, "OK %d\n", retired),
  # and the floor's fmt.Fprintf(conn, "WEAK %s\n", reason) (NWP-20261115-04), which the case below reads as the code WEAK.
  odd=$(printf '%s\n' "$live" | grep -E '(^|[^A-Za-z0-9_.])say\(|fmt\.Fprintf?\(conn,|conn\.Write\(' \
    | grep -vE 'say\("[^"]*"\)|fmt\.Fprint\(conn, "[^"]*\\n"\)|say := func\(code string\)|fmt\.Fprint\(conn, code\+"\\n"\)|fmt\.Fprintf\(conn, "OK %d\\n", retired\)|fmt\.Fprintf\(conn, "WEAK %s\\n", reason\)')
  if [ -n "$odd" ]; then echo "  FAIL  handleRotate sends a reply this suite cannot read as a literal: $odd" >&2; return 1; fi
  case "$live" in
    *'fmt.Fprintf(conn, "WEAK %s\n", reason)'*) codes=$(printf '%s\nWEAK\n' "$codes" | sort -u) ;;
  esac
  n=$(printf '%s\n' "$codes" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$n" -lt 8 ]; then echo "  FAIL  extraction found $n codes in handleRotate, want at least 8" >&2; return 1; fi
  for code in ERR BLANK ERR-SESSION WEAK; do
    printf '%s\n' "$codes" | grep -qx -- "$code" || { echo "  FAIL  extraction found no $code in handleRotate" >&2; bad=1; }
  done
  d=$(mktemp -d -p "$W") || return 1
  build "$src" "$d" || { rm -rf "$d"; echo "  FAIL  RotateCopy does not compile" >&2; return 1; }
  # shellcheck disable=SC2086
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RotateCopyCases probe $codes 2>&1) \
    || { echo "  FAIL  the probe did not run: $out" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
  for code in $codes; do
    [ "$code" = ERR ] && continue
    line=$(printf '%s\n' "$out" | grep -F -- "$code	" | head -1)
    same=${line##*	}
    [ "$same" = 0 ] || { echo "  FAIL  $code falls to the default copy" >&2; bad=1; }
  done
  for a in $codes; do
    [ "$a" = ERR ] && continue
    for b in $codes; do
      [ "$a" = "$b" ] && continue
      case "$b" in "$a"*) echo "  FAIL  $a is a prefix of $b" >&2; bad=1 ;; esac
    done
  done
  [ "$bad" -eq 0 ] && echo "codes: ok ($n codes: $(printf '%s' "$codes" | tr '\n' ' '))"
  [ "$bad" -eq 0 ]
}

# source_checks <ProfileActivity.java> -> check (b).
source_checks() {
  local f="$1" body bad=0 n
  body=$(awk '/private void showChangePass\(/ { on = 1 } on && !/^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f")
  [ -n "$body" ] || { echo "  FAIL  showChangePass not found in $f" >&2; return 1; }
  n=$(printf '%s\n' "$body" | awk '/RotateCopy\.failText\(r\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 2 ] || { echo "  FAIL  showChangePass does not render through RotateCopy.failText(r) (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/RotateCopy\.failIsError\(r\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  showChangePass does not pick its style with RotateCopy.failIsError(r)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/RotateCopy\.changed\(RotateCopy\.retired\(r\)\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the OK branch does not use RotateCopy.changed(RotateCopy.retired(r))" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/"ERR-/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  showChangePass holds an \"ERR- literal" >&2; bad=1; }
  n=$(awk '/rotatedRetired|changedCopy/ { n++ } END { print n + 0 }' "$f")
  [ "$n" -eq 0 ] || { echo "  FAIL  rotatedRetired / changedCopy still in ProfileActivity" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
codes_check "$AGENT" "$SUT" || { echo "FAILED (codes)"; exit 1; }
source_checks "$SCREEN" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RotateCopy.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RotateCopy.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutg() { # mutg <label> <perl-expr>   (mutates a copy of main.go; check (a) must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/main.go"
  cp "$AGENT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$AGENT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  codes_check "$c" "$SUT" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
muts() { # muts <label> <perl-expr>   (mutates ProfileActivity.java; pin (b) must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$SCREEN" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SCREEN" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_checks "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
mutp() { # mutp <label> <perl main.go> <perl RotateCopy.java> <stderr line>   (mutates both; check (a) must fail on it)
  local d g c rc err; d=$(mktemp -d -p "$W") || return 1; g="$d/main.go"; c="$d/RotateCopy.java"
  cp "$AGENT" "$g"; cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$g" || ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$AGENT" "$g" || cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  err=$(codes_check "$g" "$c" 2>&1 >/dev/null); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  printf '%s\n' "$err" | grep -qF -- "$4" || { echo "  WRONG     $1 -- failed, but not on: $4"; return 1; }
  echo "  convicted $1"
}
fails=0
mut "C1 ERR-SECRET matched by prefix" 's/"ERR-SECRET"\.equals\(r\)/r.startsWith("ERR-SE")/' || fails=$((fails+1))
mut "C2 the ERR-SESSION arm deleted" 's/\s*if \("ERR-SESSION"\.equals\(r\)\) return [^;]*;//s' || fails=$((fails+1))
mut "C3 ERR-SESSION shown as an error" 's/return !"ERR-SESSION"\.equals\(r\);/return true;/' || fails=$((fails+1))
mut "C4 one other phone gets the plural line" 's/n == 1 \? "Your other phone can.t open this profile until you add it again there"/n == 1 ? "Your other phones can\x27t open this profile until you add each of them again there"/' || fails=$((fails+1))
mut "C5 retired keeps a negative count" 's/return n < 0 \? -1 : n;/return n;/' || fails=$((fails+1))
mutg "C8 a code with a digit (ERR-SESSION2)" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1say("ERR-SESSION2")/' || fails=$((fails+1))
mutg "C9 a reply the extraction cannot read" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1say("ERR-"+"X")/' || fails=$((fails+1))
mutg "C6 the daemon gains a code" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1say("ERR-NEWCODE")/' || fails=$((fails+1))
muts "C7 showChangePass renders a literal" 's/RotateCopy\.failText\(r\)/"couldn\x27t change"/' || fails=$((fails+1))
mutp "C10 a code that is a prefix of others (ERR-SE)" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1say("ERR-SE")/' \
  's/(if \(r == null\) r = "";)/$1\n        if ("ERR-SE".equals(r)) return "x";/' "ERR-SE is a prefix of" || fails=$((fails+1))
mutg "C11 a reply written with Fprintf" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1fmt.Fprintf(conn, "ERR-%s\\n", "X")/' || fails=$((fails+1))
mutg "C12 a reply written with conn.Write" 's/(\t+)say\("ERR-STORE"\)/$1say("ERR-STORE")\n$1conn.Write([]byte("ERR-NEW\\n"))/' || fails=$((fails+1))
mut "C13 the WEAK arm deleted" 's/\n\s*if \("WEAK"\.equals\(r\) \|\| r\.startsWith\("WEAK "\)\) \{.*?\n        \}//s' || fails=$((fails+1))
mutg "C14 handleRotate loses the floor" 's/(func handleRotate\([^\n]*\n(?:\t\/\/[^\n]*\n)*)\tif floorEnforced\(\) \{\n.*?\n\t\}\n/$1/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
