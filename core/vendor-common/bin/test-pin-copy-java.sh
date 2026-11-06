#!/usr/bin/env bash
# test-pin-copy-java.sh [--mutate] -- NWP-20261124-10: the Session PIN screen words every SET-PIN reply, BUSY and no
# answer included. SET-PIN used to queue on sessionMu behind a materialise or a sign-in, past the chooser's read; it
# now answers BUSY, and the screen matched replies with startsWith and had no BUSY words, so BUSY and a lost reply both
# read "couldn't save the PIN -- try again". Runs core/chooser/tests/pin-copy (PinCopy.setText and clearText, compiled
# and EXECUTED), then three source checks:
#   s1  ProfileActivity.showSessionPin's Set PIN reply block renders PinCopy.setText(r), and matches no reply itself;
#   s2  its Remove PIN reply block renders PinCopy.clearText(r), and matches no reply itself;
#   s3  the SET-PIN arm of core/agent/main.go sends only codes PinCopy names (OK, ERR-FLOOR, ERR-NOTSTORED,
#       ERR-NOSESSION; ERR is the default line), and PinCopy names each of them. BUSY is the dispatcher's.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# does not fail with its expected text (BROKEN) counts as a failure, never a pass.
#
#   bash test-pin-copy-java.sh            # the cases
#   bash test-pin-copy-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-pin-copy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
PC="$ROOT/core/chooser/src/com/nowhere/chooser/PinCopy.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
MG="$ROOT/core/agent/main.go"

# between <text> <from> <to>: the lines of text from the first holding <from> to the next holding <to> (fixed strings,
# passed through the environment because awk -v would turn their backslash-n into a newline).
between() {
  A="$2" B="$3" awk 'index($0, ENVIRON["A"]) { on=1 } on { print } on && index($0, ENVIRON["B"]) { exit }' <<<"$1"
}

# check <PinCopy.java> <ProfileActivity.java> <main.go>: the cases, then the three source checks.
check() {
  local pc=$1 pa=$2 mg=$3 body blk arm codes c n=0
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/pin-copy/run.sh" "$pc" || return 1
  # showSessionPin, up to the next method.
  body=$(awk '/^    private void showSessionPin\(\) \{/{on=1; print; next} on && /^    private /{exit} on' "$pa")
  [ -n "$body" ] || { echo "FAIL: showSessionPin is gone"; return 1; }
  # (s1) the Set PIN reply block, from its SET-PIN send to its thread's name
  blk=$(between "$body" 'sendDaemon("SET-PIN\n" + p + "\n")' '"nowhere-set-pin"')
  [ -n "$blk" ] || { echo "FAIL s1: showSessionPin has no Set PIN block (sendDaemon(\"SET-PIN\\n\" + p + \"\\n\") .. \"nowhere-set-pin\")"; return 1; }
  case "$blk" in *"PinCopy.setText(r)"*) ;; *) echo "FAIL s1: the Set PIN reply block does not render PinCopy.setText(r)"; return 1 ;; esac
  case "$blk" in *"startsWith"*) echo "FAIL s1: the Set PIN reply block matches a reply by startsWith"; return 1 ;; esac
  case "$blk" in *"couldn't save the PIN"*) echo "FAIL s1: the Set PIN reply block words a reply itself"; return 1 ;; esac
  # (s2) the Remove PIN reply block, from its empty SET-PIN send to its thread's name
  blk=$(between "$body" 'sendDaemon("SET-PIN\n\n")' '"nowhere-clear-pin"')
  [ -n "$blk" ] || { echo "FAIL s2: showSessionPin has no Remove PIN block (sendDaemon(\"SET-PIN\\n\\n\") .. \"nowhere-clear-pin\")"; return 1; }
  case "$blk" in *"PinCopy.clearText(r)"*) ;; *) echo "FAIL s2: the Remove PIN reply block does not render PinCopy.clearText(r)"; return 1 ;; esac
  case "$blk" in *"startsWith"*) echo "FAIL s2: the Remove PIN reply block matches a reply by startsWith"; return 1 ;; esac
  case "$blk" in *"couldn't remove the PIN"*) echo "FAIL s2: the Remove PIN reply block words a reply itself"; return 1 ;; esac
  # (s3) the SET-PIN arm of handleLogin, up to its closing brace at one tab
  arm=$(awk '/^\tif name == "SET-PIN" \{$/{on=1; print; next} on && /^\t\}$/{exit} on' "$mg")
  [ -n "$arm" ] || { echo "FAIL s3: main.go has no SET-PIN arm"; return 1; }
  case "$arm" in *"Fprintf(conn"*) echo "FAIL s3: the SET-PIN arm sends a computed reply (Fprintf(conn ...)) this suite cannot read"; return 1 ;; esac
  codes=$(sed -n 's/.*fmt\.Fprint(conn, "\([^"\\]*\)\\n").*/\1/p' <<<"$arm" | sort -u)
  [ -n "$codes" ] || { echo "FAIL s3: the SET-PIN arm sends no fmt.Fprint(conn, \"<CODE>\\n\") reply"; return 1; }
  while IFS= read -r c; do
    n=$((n+1))
    case "$c" in OK|ERR-FLOOR|ERR-NOTSTORED|ERR-NOSESSION|ERR) ;;
      *) echo "FAIL s3: the SET-PIN arm sends \"$c\", a code PinCopy does not name"; return 1 ;; esac
    [ "$c" = ERR ] && continue
    case "$(cat "$pc")" in *"\"$c\".equals("*) ;; *) echo "FAIL s3: PinCopy does not name \"$c\", which the SET-PIN arm sends"; return 1 ;; esac
  done <<<"$codes"
  echo "  ok   source checks s1 s2 s3 ($n code(s) the SET-PIN arm sends, each named)"
}
check "$PC" "$PA" "$MG" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or fails for another reason proves nothing)"
mut() { # mut <label> <pc|pa|mg> <perl-expr> <text the failure must contain>
  local d f o pc pa mg out rc
  d=$(mktemp -d -p "$W"); pc=$PC; pa=$PA; mg=$MG
  case "$2" in
    pc) o=$PC; f="$d/PinCopy.java"; pc=$f ;;
    pa) o=$PA; f="$d/ProfileActivity.java"; pa=$f ;;
    mg) o=$MG; f="$d/main.go"; mg=$f ;;
    *) echo "  ERROR     $1 -- unknown kind $2"; return 1 ;;
  esac
  cp "$o" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$o" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$pc" "$pa" "$mg" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 setText(\"\") falls to the couldn't-save line" pc 's/\n\s*if \(r\.isEmpty\(\)\) return "The phone[^;]*;//s' 'FAIL set: no answer ("")' || fails=$((fails+1))
mut "M2 BUSY falls to the default line" pc 's/\n\s*if \("BUSY"\.equals\(r\)\) return [^\n]*//' "FAIL set: BUSY says nothing changed" || fails=$((fails+1))
mut "M3 ERR-FLOOR matched by startsWith" pc 's/"ERR-FLOOR"\.equals\(trim\(reply\)\)/trim(reply).startsWith("ERR-FLOOR")/' "FAIL set: ERR-FLOOR-X is not ERR-FLOOR" || fails=$((fails+1))
mut "M4 the Remove block reverted to its inline text" pa 's/StatusLine\.error\(msg, err\);(\n\s*\}\n\s*\}\);\n\s*\}, "nowhere-clear-pin")/StatusLine.error(msg, "couldn'"'"'t remove the PIN \x{2014} try again");$1/; s/final String err = PinCopy\.clearText\(r\);/final String err = r.startsWith("OK") ? null : "";/' "FAIL s2" || fails=$((fails+1))
mut "M5 the Set block reverted to its startsWith chain" pa 's/final String err = PinCopy\.setText\(r\);/final String err = r.startsWith("OK") ? null : r.startsWith("ERR-FLOOR") ? "the PIN must be 4-16 digits" : "couldn'"'"'t save the PIN - try again";/' "FAIL s1" || fails=$((fails+1))
mut "M6 a new code in the SET-PIN arm (copy of main.go)" mg 's/(if pin != "" && !pinFloor\(pin\) \{\n\t\t\tfmt\.Fprint\(conn, ")ERR-FLOOR/${1}ERR-PINLEN/' 'FAIL s3: the SET-PIN arm sends "ERR-PINLEN"' || fails=$((fails+1))
mut "M7 OK matched by startsWith" pc 's/"OK"\.equals\(r\)/r.startsWith("OK")/' "FAIL set: OKAY is not OK" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
