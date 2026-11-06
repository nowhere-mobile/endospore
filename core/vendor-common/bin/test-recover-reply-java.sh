#!/usr/bin/env bash
# test-recover-reply-java.sh [--mutate] -- the Reset passphrase screen's reply copy, run under javac (NWP-20261115-10).
#
# WHY THIS IS COMMITTED. buildRecoverScreen rendered the daemon's RECOVER reply through an inline ternary. When RECOVER
# began to refuse a below-floor new passphrase with "WEAK <reason>", that ternary would have shown it as "couldn't
# reset -- check the name and recovery code", which blames a correct recovery code. RecoverCopy (pure, java.lang only)
# is compiled here with its cases; (a) every code recoverReply in core/agent/main.go can send must be read by this
# suite, OK, ERR-STORE, ERR-MOVED (NWP-20261116-06), BLANK and WEAK must all be there, every code but OK and BLANK must
# get a copy of its own, and no code may be a prefix of another; (b) buildRecoverScreen must render through RecoverCopy.failText(r) and hold no "ERR-
# literal.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-recover-reply-java.sh            # the cases, check (a), pin (b)
#   bash test-recover-reply-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RecoverCopy.java"
SCREEN="$SRC/ChooserActivity.java"
AGENT="$root/core/agent/main.go"
CASES="$root/core/chooser/tests/recover-reply/RecoverReplyCases.java"
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

# build <RecoverCopy.java> <dir> -> compiles RecoverCopy with the cases alone into <dir>/out; 0 ok, 3 no compile.
build() {
  local src="$1" d="$2"
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RecoverCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RecoverReplyCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || return 3
}

# suite <RecoverCopy.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RecoverCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  build "$src" "$d" || { rm -rf "$d"; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RecoverReplyCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# codes_check <main.go> <RecoverCopy.java> -> check (a). 0 when every code recoverReply sends is read here, the five
# known codes are all present, every code but OK and BLANK has its own copy, and none is a prefix of another.
codes_check() {
  local go="$1" src="$2" body live odd codes n a b d out line code same bad=0
  [ -f "$src" ] || { echo "  FAIL  RecoverCopy.java does not exist" >&2; return 1; }
  body=$(awk '/^func recoverReply\(/ { on = 1 } on { print } on && /^}/ { exit }' "$go")
  [ -n "$body" ] || { echo "  FAIL  recoverReply not found in $go" >&2; return 1; }
  live=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*//')
  # The literal form `return "<code>"`, and the one named form `return "WEAK " + reason`, which is the code WEAK.
  codes=$( {
    printf '%s\n' "$live" | grep -oE 'return "[^"]*"[[:space:]]*$' | sed -E 's/^return "([^"]*)"[[:space:]]*$/\1/'
    printf '%s\n' "$live" | grep -E 'return "WEAK " \+ reason[[:space:]]*$' | sed 's/.*/WEAK/'
  } | sort -u)
  # A return this extraction cannot read is a failure, never a silent omission: every line holding `return` must be
  # one of the two forms above, or the one named exception, the daemonVaultErr closure's call of recoverVault.
  odd=$(printf '%s\n' "$live" | grep -E '(^|[^A-Za-z0-9_])return([^A-Za-z0-9_]|$)' \
    | grep -vE 'return "[^"]*"[[:space:]]*$|return "WEAK " \+ reason[[:space:]]*$|err := daemonVaultErr\(func\(\) error \{ return recoverVault\("s3", name, mnemonic, newpass\) \}\)')
  if [ -n "$odd" ]; then echo "  FAIL  recoverReply returns something this suite cannot read: $odd" >&2; return 1; fi
  n=$(printf '%s\n' "$codes" | awk 'NF { n++ } END { print n + 0 }')
  for code in OK ERR-STORE ERR-MOVED BLANK WEAK; do
    printf '%s\n' "$codes" | grep -qx -- "$code" || { echo "  FAIL  extraction found no $code in recoverReply" >&2; bad=1; }
  done
  d=$(mktemp -d -p "$W") || return 1
  build "$src" "$d" || { rm -rf "$d"; echo "  FAIL  RecoverCopy does not compile" >&2; return 1; }
  # shellcheck disable=SC2086
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RecoverReplyCases probe $codes 2>&1) \
    || { echo "  FAIL  the probe did not run: $out" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
  for code in $codes; do
    case "$code" in OK|BLANK) continue ;; esac
    line=$(printf '%s\n' "$out" | grep -F -- "$code	" | head -1)
    same=${line##*	}
    [ "$same" = 0 ] || { echo "  FAIL  $code falls to the default copy" >&2; bad=1; }
  done
  for a in $codes; do
    for b in $codes; do
      [ "$a" = "$b" ] && continue
      case "$b" in "$a"*) echo "  FAIL  $a is a prefix of $b" >&2; bad=1 ;; esac
    done
  done
  [ "$bad" -eq 0 ] && echo "codes: ok ($n codes: $(printf '%s' "$codes" | tr '\n' ' '))"
  [ "$bad" -eq 0 ]
}

# source_checks <ChooserActivity.java> -> check (b).
source_checks() {
  local f="$1" body bad=0 n
  body=$(awk '/private View buildRecoverScreen\(\)/ { on = 1 } on && !/^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f")
  [ -n "$body" ] || { echo "  FAIL  buildRecoverScreen not found in $f" >&2; return 1; }
  n=$(printf '%s\n' "$body" | awk '/RecoverCopy\.failText\(r\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  buildRecoverScreen does not render through RecoverCopy.failText(r) (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/"ERR-/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  buildRecoverScreen holds an \"ERR- literal" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/couldn.t reset/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  buildRecoverScreen holds its own couldn't-reset text" >&2; bad=1; }
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
mut() { # mut <label> <perl-expr>   (mutates RecoverCopy.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RecoverCopy.java"
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
muts() { # muts <label> <perl-expr>   (mutates a copy of ChooserActivity.java; pin (b) must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$SCREEN" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SCREEN" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_checks "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "R1 the WEAK arm deleted" 's/\n[ \t]*if \("WEAK"\.equals\(r\) \|\| r\.startsWith\("WEAK "\)\) \{.*?\n        \}//s' || fails=$((fails+1))
mut "R2 ERR-STORE matched by prefix" 's/"ERR-STORE"\.equals\(r\)/r.startsWith("ERR-S")/' || fails=$((fails+1))
mutg "R3 the floor block deleted" 's/\n\tif floorEnforced\(\) \{\n\t\tif ok, reason := passphraseStrong\(name, newpass\); !ok \{\n\t\t\treturn "WEAK " \+ reason\n\t\t\}\n\t\}//' || fails=$((fails+1))
mutg "R4 the daemon gains a code" 's/(\n(\t+)return "ERR-STORE"\n)/$1$2return "ERR-NEW"\n/' || fails=$((fails+1))
mutg "R5 a return the extraction cannot read" 's/(\n(\t+)return "ERR-STORE"\n)/$1$2return "ERR-" + "X"\n/' || fails=$((fails+1))
muts "R6 the failure branch renders a literal" 's/RecoverCopy\.failText\(r\)/"couldn\x27t reset"/' || fails=$((fails+1))
mut "R7 the ERR-MOVED arm deleted" 's/\n[ \t]*if \("ERR-MOVED"\.equals\(r\)\) return [^\n]*//' || fails=$((fails+1))
mut "R8 ERR-MOVED matched by prefix" 's/"ERR-MOVED"\.equals\(r\)/r.startsWith("ERR-MOVE")/' || fails=$((fails+1))
mutg "R9 the daemon drops ERR-MOVED" 's/\n\t+case errors\.Is\(err, errRecoverMoved\):[^\n]*\n\t+return "ERR-MOVED"//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
