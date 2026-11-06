#!/usr/bin/env bash
# test-add-device-copy-java.sh [--mutate] -- the Add this phone screen's reply copy, run under javac (NWP-20261116-28).
#
# WHY THIS IS COMMITTED. buildAddPhoneScreen read the daemon's ADD-DEVICE reply through an inline startsWith chain that
# no suite named, and anything it did not match, a lost reply ("") included, read "couldn't reach the store". The gate
# reads 90 s while the daemon's ADD-DEVICE arm allows 120 s, so an add that landed late was reported as a store failure.
# AddDeviceCopy (pure, java.lang only) is compiled here with its cases: a lost reply must say to tap Add again before
# signing in. (a) every code handleAddDevice in core/agent/main.go can send must get a copy of its own but OK and ERR,
# and no code but the bare ERR may be a prefix of another; (b) buildAddPhoneScreen must render through AddDeviceCopy
# and hold no "ERR- literal.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-add-device-copy-java.sh            # the cases, check (a), pin (b)
#   bash test-add-device-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/AddDeviceCopy.java"
SCREEN="$SRC/ChooserActivity.java"
AGENT="$root/core/agent/main.go"
CASES="$root/core/chooser/tests/add-device-copy/AddDeviceCopyCases.java"
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

# build <AddDeviceCopy.java> <dir> -> compiles AddDeviceCopy with the cases alone into <dir>/out; 0 ok, 3 no compile.
build() {
  local src="$1" d="$2"
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/AddDeviceCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/AddDeviceCopyCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || return 3
}

# suite <AddDeviceCopy.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  AddDeviceCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  build "$src" "$d" || { rm -rf "$d"; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AddDeviceCopyCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# codes_check <main.go> <AddDeviceCopy.java> -> check (a). 0 when every code handleAddDevice sends has its own copy
# (OK and the bare ERR excepted) and none but the bare ERR is a prefix of another.
codes_check() {
  local go="$1" src="$2" body live odd codes n a b d out line code same bad=0
  [ -f "$src" ] || { echo "  FAIL  AddDeviceCopy.java does not exist" >&2; return 1; }
  body=$(awk '/^func handleAddDevice\(/ { on = 1 } on { print } on && /^}/ { exit }' "$go")
  [ -n "$body" ] || { echo "  FAIL  handleAddDevice not found in $go" >&2; return 1; }
  live=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*//')
  codes=$(printf '%s\n' "$live" | grep -oE 'fmt\.Fprint\(conn, "[^"]*\\n"\)' \
    | sed -E 's/^fmt\.Fprint\(conn, "([^"]*)\\n"\)$/\1/' | sort -u)
  # A reply this extraction cannot read as a literal is a failure, never a silent omission. Every use of conn below
  # the signature must be the plain fmt.Fprint(conn, "<literal>\n") form: Fprintln, Fprintf, io.WriteString,
  # conn.Write, a writer wrapped round conn, or conn handed to a helper could each send a code this suite never sees.
  # So the plain forms (and then any trailing comment) are cut from each line, and a conn that is left is refused.
  odd=$(printf '%s\n' "$live" | sed 1d \
    | sed -E 's/fmt\.Fprint\(conn, "[^"]*\\n"\)//g; s@//.*$@@' | grep -nE '(^|[^[:alnum:]_])conn([^[:alnum:]_]|$)')
  if [ -n "$odd" ]; then echo "  FAIL  handleAddDevice sends a reply this suite cannot read as a literal: $odd" >&2; return 1; fi
  n=$(printf '%s\n' "$codes" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$n" -lt 8 ]; then echo "  FAIL  extraction found $n codes in handleAddDevice, want at least 8" >&2; return 1; fi
  for code in OK ERR BLANK NOSTORE ERR-BADPASS; do
    printf '%s\n' "$codes" | grep -qx -- "$code" || { echo "  FAIL  extraction found no $code in handleAddDevice" >&2; bad=1; }
  done
  d=$(mktemp -d -p "$W") || return 1
  build "$src" "$d" || { rm -rf "$d"; echo "  FAIL  AddDeviceCopy does not compile" >&2; return 1; }
  # shellcheck disable=SC2086
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AddDeviceCopyCases probe $codes 2>&1) \
    || { echo "  FAIL  the probe did not run: $out" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
  for code in $codes; do
    case "$code" in OK|ERR) continue ;; esac
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

# source_checks <ChooserActivity.java> -> pin (b).
source_checks() {
  local f="$1" body bad=0 n
  body=$(awk '/private View buildAddPhoneScreen\(/ { on = 1 } on && !/^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f")
  [ -n "$body" ] || { echo "  FAIL  buildAddPhoneScreen not found in $f" >&2; return 1; }
  n=$(printf '%s\n' "$body" | awk '/if \(AddDeviceCopy\.added\(reply\)\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  buildAddPhoneScreen does not test AddDeviceCopy.added(reply) (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/StatusLine\.error\(msg, AddDeviceCopy\.failText\(reply\)\);/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  buildAddPhoneScreen does not render through AddDeviceCopy.failText(reply) (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/"ERR-/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  buildAddPhoneScreen holds an \"ERR- literal (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/reply\.startsWith\(/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  buildAddPhoneScreen still matches the reply by prefix (found $n)" >&2; bad=1; }
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
mut() { # mut <label> <perl-expr>   (mutates AddDeviceCopy.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/AddDeviceCopy.java"
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
mut "M1 a lost reply mapped to the store text" \
  's/if \(r\.isEmpty\(\)\) return "the phone didn.t answer[^;]*;\n//s' || fails=$((fails+1))
mut "M2 the lost-reply text says to sign in first" \
  's/tap Add "\n\s*\+ "again \(adding a phone twice is safe\), then sign in with your passphrase"/sign in with your passphrase first, then tap Add again (adding a phone twice is safe)"/s' || fails=$((fails+1))
mut "M3 ERR-BADPASS matched by startsWith(\"ERR-BADP\")" \
  's/"ERR-BADPASS"\.equals\(r\)/r.startsWith("ERR-BADP")/' || fails=$((fails+1))
mut "M4 added() by startsWith(\"OK\")" \
  's/"OK"\.equals\(r\.trim\(\)\)/r.trim().startsWith("OK")/' || fails=$((fails+1))
mutg "M5 handleAddDevice gains a code (ERR-NEW)" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1fmt.Fprint(conn, "ERR-NEW\\n")/' || fails=$((fails+1))
muts "M6 the failure branch renders a literal" \
  's/StatusLine\.error\(msg, AddDeviceCopy\.failText\(reply\)\);/StatusLine.error(msg, "couldn\x27t reach the store — check your connection and try again");/' || fails=$((fails+1))
mut "M7 the BLANK arm deleted" 's/\n\s*if \("BLANK"\.equals\(r\)\) return [^;]*;//' || fails=$((fails+1))
mutg "M8 a reply written with Fprintf" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1fmt.Fprintf(conn, "ERR-%s\\n", "X")/' || fails=$((fails+1))
mutg "M9 a reply written with conn.Write" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1conn.Write([]byte("ERR-NEW\\n"))/' || fails=$((fails+1))
mutg "M10 a code that is a prefix of another (ERR-BAD)" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1fmt.Fprint(conn, "ERR-BAD\\n")/' || fails=$((fails+1))
muts "M11 the success branch matches by prefix" \
  's/if \(AddDeviceCopy\.added\(reply\)\) \{/if (reply.startsWith("OK")) {/' || fails=$((fails+1))
mutg "M12 a reply written with Fprintln" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1fmt.Fprintln(conn, "ERR-NEW")/' || fails=$((fails+1))
mutg "M13 a reply written with io.WriteString" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1io.WriteString(conn, "ERR-NEW\\n")/' || fails=$((fails+1))
mutg "M14 conn handed to a helper that replies" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n")\n$1replyAddDevice(conn, "ERR-NEW")/' || fails=$((fails+1))
mutg "M15 a second plain reply on a line that also writes with Fprintln" \
  's/(\t+)fmt\.Fprint\(conn, "ERR-BADPASS\\n"\)/$1fmt.Fprint(conn, "ERR-BADPASS\\n"); fmt.Fprintln(conn, "ERR-NEW")/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
