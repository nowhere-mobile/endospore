#!/usr/bin/env bash
# test-promote-copy-java.sh [--mutate] -- the Save to your store ceremony's PROMOTE2 reply copy, under javac
# (NWP-20261116-15).
#
# WHY THIS IS COMMITTED. ProfileActivity.handlePromoteReply is the only reader of the PROMOTE2 reply, and no suite named
# it. It had three defects: a failed save left the ceremony up with a dead "Saving…" button; ERR-SESSION (the screen
# lock took the new passphrase, nothing was saved) said "Couldn't save — try again", which a retry can never satisfy;
# and a lost reply (the chooser reads 90 s, the daemon has 120 s) said the same, though the save may have landed.
# PromoteCopy (pure, java.lang only) is compiled here with its cases; (a) every code handlePromote2, promoteGuards and
# promoteToStore in core/agent/main.go send must have a kind, and only BUSY, ERR-VAULT, ERR-NOSESSION and ERR-NOPASS
# may fall to the default copy; (b) handlePromoteReply must switch on PromoteCopy.kind(r), re-open the ceremony in its
# CEREMONY arm and hold no "ERR- literal.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
# A plain run runs all three checks and reports each before it exits, so one run on an old tree shows every gap.
#
#   bash test-promote-copy-java.sh            # the cases, check (a), pin (b)
#   bash test-promote-copy-java.sh --mutate   # ... plus broken copies that must each be CONVICTED
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/PromoteCopy.java"
SCREEN="$SRC/ProfileActivity.java"
AGENT="$root/core/agent/main.go"
CASES="$root/core/chooser/tests/promote-copy/PromoteCopyCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
# The codes that may render as the default "Couldn't save — try again": for each, nothing was saved and a retry from
# the ceremony is the right next step. A new code fails check (a) until PromoteCopy classifies it or it joins this list.
DEFAULT_SET="BUSY ERR-NOPASS ERR-NOSESSION ERR-VAULT"

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

# build <PromoteCopy.java> <dir> -> compiles PromoteCopy with the cases alone into <dir>/out; 0 ok, 3 no compile.
build() {
  local src="$1" d="$2"
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/PromoteCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/PromoteCopyCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || return 3
}

# suite <PromoteCopy.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  PromoteCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  build "$src" "$d" || { rm -rf "$d"; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PromoteCopyCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# body <main.go> <func> -> the function's lines, whole-line comments dropped.
body() {
  awk -v f="$2" '$0 ~ "^func " f "\\(" { on = 1 } on { print } on && /^}/ { exit }' "$1" | grep -v '^[[:space:]]*//'
}

# codes_check <main.go> <PromoteCopy.java> -> check (a). 0 when every code the three PROMOTE2 functions send has a
# kind, exactly DEFAULT_SET falls to the default, and no code but the two payload forms is a prefix of another.
codes_check() {
  local go="$1" src="$2" fn b live="" odd codes n a b2 d out code line bad=0 dflt want
  local -a probe=()
  [ -f "$src" ] || { echo "  FAIL  PromoteCopy.java does not exist" >&2; return 1; }
  for fn in handlePromote2 promoteGuards promoteToStore; do
    b=$(body "$go" "$fn")
    [ -n "$b" ] || { echo "  FAIL  $fn not found in $go" >&2; return 1; }
    live=$(printf '%s\n%s\n' "$live" "$b")
  done
  codes=$(printf '%s\n' "$live" | grep -oE 'fmt\.Fprint\(conn, "[^"]*\\n"\)' \
    | sed -E 's/^fmt\.Fprint\(conn, "([^"]*)\\n"\)$/\1/' | sort -u)
  # A reply this extraction cannot read is a failure, never a silent omission. Every line that names conn must be a
  # plain fmt.Fprint(conn, "<literal>\n"), one of the two payload forms -- fmt.Fprintf(conn, "WEAK %s\n", reason) and
  # fmt.Fprintf(conn, "OK RECOVERY %s\n", <identifier>) (any identifier: NOWHERE-1228 adds a repeat-PROMOTE2 write of
  # the latter) -- a function signature, or the hand-off to promoteGuards / promoteToStore, whose bodies are read too.
  odd=$(printf '%s\n' "$live" | grep -E '(^|[^A-Za-z0-9_])conn([^A-Za-z0-9_]|$)' \
    | grep -vE 'fmt\.Fprint\(conn, "[^"]*\\n"\)|fmt\.Fprintf\(conn, "WEAK %s\\n", reason\)|fmt\.Fprintf\(conn, "OK RECOVERY %s\\n", [A-Za-z_][A-Za-z0-9_]*\)|^func [A-Za-z0-9_]+\(conn net\.Conn,|(^|[^A-Za-z0-9_.])(promoteGuards|promoteToStore)\(conn, ')
  if [ -n "$odd" ]; then echo "  FAIL  a PROMOTE2 function sends a reply this suite cannot read as a literal: $odd" >&2; return 1; fi
  case "$live" in *'fmt.Fprintf(conn, "WEAK %s\n", reason)'*) codes=$(printf '%s\nWEAK\n' "$codes" | sort -u) ;; esac
  if printf '%s\n' "$live" | grep -qE 'fmt\.Fprintf\(conn, "OK RECOVERY %s\\n", [A-Za-z_][A-Za-z0-9_]*\)'; then
    codes=$(printf '%s\nOK RECOVERY\n' "$codes" | sort -u)
  fi
  n=$(printf '%s\n' "$codes" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$n" -lt 12 ]; then echo "  FAIL  extraction found $n codes in the PROMOTE2 functions, want at least 12" >&2; return 1; fi
  for want in ERR-SESSION WEAK "OK RECOVERY"; do
    printf '%s\n' "$codes" | grep -qxF -- "$want" || { echo "  FAIL  extraction found no $want" >&2; bad=1; }
  done
  # The probe takes each code as one argument (OK RECOVERY has a space); a payload form gets a sample payload.
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    case "$code" in
      WEAK) probe+=("WEAK sample reason") ;;
      "OK RECOVERY") probe+=("OK RECOVERY w1 w2") ;;
      *) probe+=("$code") ;;
    esac
  done <<<"$codes"
  d=$(mktemp -d -p "$W") || return 1
  build "$src" "$d" || { rm -rf "$d"; echo "  FAIL  PromoteCopy does not compile" >&2; return 1; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PromoteCopyCases probe \
    "${probe[@]}" 2>&1) || { echo "  FAIL  the probe did not run: $out" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
  n=$(printf '%s\n' "$out" | awk -F '\t' 'NF == 3 { n++ } END { print n + 0 }')
  [ "$n" -eq "${#probe[@]}" ] || { echo "  FAIL  the probe answered $n of ${#probe[@]} codes: $out" >&2; return 1; }
  dflt=$(printf '%s\n' "$out" | awk -F '\t' '$3 == 1 { print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$dflt" = "$DEFAULT_SET" ] || {
    echo "  FAIL  the codes that fall to the default are [$dflt], want exactly [$DEFAULT_SET]" >&2; bad=1; }
  while IFS= read -r a; do
    case "$a" in ""|WEAK|"OK RECOVERY") continue ;; esac
    while IFS= read -r b2; do
      [ -n "$b2" ] && [ "$a" != "$b2" ] || continue
      case "$b2" in "$a"*) echo "  FAIL  $a is a prefix of $b2" >&2; bad=1 ;; esac
    done <<<"$codes"
  done <<<"$codes"
  [ "$bad" -eq 0 ] && { echo "codes: ok ($(printf '%s\n' "$codes" | grep -c .) codes)"; printf '%s\n' "$out" | sed 's/^/  /'; }
  [ "$bad" -eq 0 ]
}

# source_checks <ProfileActivity.java> -> pin (b).
source_checks() {
  local f="$1" bad=0 n hb arm
  hb=$(awk '/private void handlePromoteReply\(/ { on = 1 } on && !/^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f")
  [ -n "$hb" ] || { echo "  FAIL  handlePromoteReply not found in $f" >&2; return 1; }
  n=$(printf '%s\n' "$hb" | awk '/switch \(PromoteCopy\.kind\(r\)\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  handlePromoteReply does not switch on PromoteCopy.kind(r) (found $n)" >&2; bad=1; }
  arm=$(printf '%s\n' "$hb" | awk '/case CEREMONY:/ { on = 1; sub(/.*case CEREMONY:/, "") } on && /case [A-Z]+:/ && !/case CEREMONY:/ { exit } on { print }')
  n=$(printf '%s\n' "$arm" | awk '/showSaveCeremony\(\)/ { n++ } END { print n + 0 }')
  [ "$n" -ge 1 ] || { echo "  FAIL  the CEREMONY arm of handlePromoteReply does not call showSaveCeremony()" >&2; bad=1; }
  n=$(printf '%s\n' "$hb" | awk '/"ERR-/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  handlePromoteReply holds an \"ERR- literal" >&2; bad=1; }
  for n in 'PromoteCopy\.recovery\(r\)' 'PromoteCopy\.text\(r\)'; do
    printf '%s\n' "$hb" | grep -qE "$n" || { echo "  FAIL  handlePromoteReply does not use ${n//\\/}" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

fail=0
echo "== $SUT"
suite "$SUT" || { echo "FAILED (cases)"; fail=1; }
codes_check "$AGENT" "$SUT" || { echo "FAILED (codes)"; fail=1; }
if source_checks "$SCREEN"; then echo "source: ok"; else echo "FAILED (source)"; fail=1; fi
[ "$fail" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates PromoteCopy.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/PromoteCopy.java"
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
mutc() { # mutc <label> <perl-expr>   (mutates PromoteCopy.java; check (a) must fail on the real main.go)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/PromoteCopy.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  codes_check "$AGENT" "$c" >/dev/null 2>&1; rc=$?
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
fails=0
mut "P1 ERR-SESSION mapped to the default" 's/\s*if \("ERR-SESSION"\.equals\(r\)\) return [^;]*;//sg' || fails=$((fails+1))
mut "P2 the no-reply text says \"Couldn't save — try again\"" \
  's/if \(r\.isEmpty\(\)\) return "The phone didn.t answer[^;]*;/if (r.isEmpty()) return "Couldn\x27t save — try again";/s' || fails=$((fails+1))
muts "P3 the CEREMONY arm no longer re-opens the ceremony" \
  's/(case CEREMONY:.*?)\n\s*showSaveCeremony\(\);/$1/s' || fails=$((fails+1))
mutg "P4 promoteGuards gains a code (ERR-NEW)" \
  's/(\nfunc promoteGuards\(.*?\n)(\t+)(fmt\.Fprint\(conn, "ERR-NOSESSION\\n"\)\n)/$1$2$3$2fmt.Fprint(conn, "ERR-NEW\\n")\n/s' || fails=$((fails+1))
mut "P5 ERR-EXISTS matched by startsWith(\"ERR-EX\")" 's/"ERR-EXISTS"\.equals\(r\)/r.startsWith("ERR-EX")/g' || fails=$((fails+1))
mutg "P6 a reply written with Fprintf" \
  's/(\nfunc promoteGuards\(.*?\n)(\t+)(fmt\.Fprint\(conn, "ERR-NOSESSION\\n"\)\n)/$1$2$3$2fmt.Fprintf(conn, "ERR-%s\\n", x)\n/s' || fails=$((fails+1))
mutg "P7 a reply written with conn.Write" \
  's/(\t+)(fmt\.Fprint\(conn, "NOCREDIT\\n"\))/$1conn.Write([]byte("ERR-NEW\\n"))\n$1$2/' || fails=$((fails+1))
mutc "P8 ERR-VAULT given a copy of its own" \
  's/(if \("ERR-REKEY"\.equals\(r\)\) return)/if ("ERR-VAULT".equals(r)) return "x";\n        $1/' || fails=$((fails+1))
mut "P9 WEAK matched by a bare startsWith(\"WEAK\")" \
  's/"WEAK"\.equals\(r\) \|\| r\.startsWith\("WEAK "\)/r.startsWith("WEAK")/' || fails=$((fails+1))
muts "P10 handlePromoteReply renders a literal" 's/PromoteCopy\.text\(r\)/"ERR-VAULT"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
