#!/usr/bin/env bash
# test-resume-reply-java.sh [--mutate] -- the cold-lock RESUME reply verdict, run under javac (NWP-20261109-19).
#
# WHY THIS IS COMMITTED. ChooserActivity.resume() turns the daemon's reply into a screen: switch into the session,
# fall back to a fresh gate, or say "wrong PIN" and clear the entry. Two shipped fixes depend on that chain and nothing
# tested it: NWP-20261006-23 (a dead socket used to read "wrong passphrase" and clear the field; a user told their right
# passphrase is wrong may sign in fresh, which reaps the cold-locked session) and NWP-20261023-03 (ERR-WORKER-BUSY is
# rendered as "couldn't resume -- try again" with the entry kept). A startsWith("ERR") tidy-up, or a new daemon code,
# would call the owner's right PIN wrong while CI stayed green; "OK 0" used to pass `fuid >= 0` and switch to the gate.
# The verdict now lives in ResumeReply.java (pure java.lang). This suite runs it against ResumeReplyCases, then checks
#  (a) CROSS-SIDE: every reply core/agent/main.go handleResume writes to conn is in this suite's table and ResumeReply
#      gives it the table's kind (a new daemon code fails here by name: teach the chooser first);
#  (b) PINS over resume(): one ResumeReply.of call, no startsWith on the reply, passField.setText("") only under WRONG,
#      and one NOTMPFS arm (B6).
# NWP-20261117-12 (#30): the table also knows ERR-NOTMPFS -> NOTMPFS. handleLogin's dispatch (refuseNoTmpfs) answers it
# before handleResume runs, so (a) never meets it today; the table holds it so a later handleResume write maps right.
# Its text, "This phone can't sign in safely. Restart it.", is pinned in test-signin-ota-java.sh.
#
# FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-resume-reply-java.sh            # the cases, (a) and (b)
#   bash test-resume-reply-java.sh --mutate   # ... plus broken copies that must each FAIL
#   RESUME_MAIN_GO=<path> overrides core/agent/main.go for (a).
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
PARSE="$root/core/chooser/src/com/nowhere/chooser/ResumeReply.java"
RUN="$root/core/chooser/tests/resume-reply/run.sh"
GO="${RESUME_MAIN_GO:-$root/core/agent/main.go}"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its mutants" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] && [ -f "$GO" ] || { echo "FAIL: missing $SRC, $RUN or $GO" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# pins <ChooserActivity.java> -> 0 all hold, 1 one failed
pins() {
  local f="$1" b n clr nx
  b=$(body "$f" 'private void resume(final String pass, final boolean keyAlreadyAsserted) {')
  [ -n "$b" ] || { echo "  PIN B0 no resume(String, boolean) in $f" >&2; return 1; }
  n=$(printf '%s\n' "$b" | grep -cF 'ResumeReply.of(' || true)
  [ "$n" = 1 ] || { echo "  PIN B1 resume() calls ResumeReply.of( $n times, want 1" >&2; return 1; }
  nx=$(printf '%s\n' "$b" | grep -A1 -F 'String reply = sendDaemon("RESUME\n" + pass + "\n").trim();' || true)
  grep -qF 'ResumeReply.of(reply)' <<< "$nx" || {
    echo "  PIN B2 ResumeReply.of(reply) is not on the line after the sendDaemon(\"RESUME ...\") line" >&2; return 1; }
  n=$(printf '%s\n' "$b" | grep -cE '\b(reply|r)\.startsWith\(' || true)
  [ "$n" = 0 ] || { echo "  PIN B3 resume() still tests the reply with startsWith ($n)" >&2; return 1; }
  n=$(printf '%s\n' "$b" | grep -cF 'passField.setText("")' || true)
  [ "$n" = 1 ] || { echo "  PIN B4 resume() clears the entry $n times, want 1 (WRONG only)" >&2; return 1; }
  clr=$(printf '%s\n' "$b" | awk '/if \(/{last=$0} index($0, "passField.setText(\"\")"){print last; exit}')
  grep -qE '^\s*(\}\s*)?(else )?if \(v\.kind == ResumeReply\.WRONG\) \{' <<< "$clr" || {
    echo "  PIN B5 the entry is cleared under [$clr], not the WRONG arm" >&2; return 1; }
  n=$(printf '%s\n' "$b" | grep -cF 'else if (v.kind == ResumeReply.NOTMPFS) {' || true)
  [ "$n" = 1 ] || { echo "  PIN B6 resume() has $n NOTMPFS arms, want 1" >&2; return 1; }
  return 0
}

# cross <ResumeReply.java> <main.go> -> 0 pass, 1 a token is unknown or mis-mapped, >=2 broken
cross() {
  local pj="$1" go="$2" fn lines l tok busy toks args out want got t n
  fn=$(awk '/^func handleResume\(/{on=1} on{print} on && /^}/{exit}' "$go")
  [ -n "$fn" ] || { echo "FAIL: no func handleResume( in $go"; return 1; }
  busy=$(perl -ne 'print $1 if /^const workerBusy = "([^"]*)"/' "$go")
  lines=$(printf '%s\n' "$fn" | grep -F 'Fprint' | grep -F '(conn,' || true)
  toks=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if tok=$(printf '%s\n' "$l" | perl -ne 'if (/fmt\.Fprint\(conn, "([^"\\]*)\\n"\)/) { print $1; exit 0 } exit 1'); then :
    elif grep -qF 'fmt.Fprint(conn, workerBusy+"\n")' <<< "$l"; then
      [ -n "$busy" ] || { echo "FAIL: workerBusy is not a string const in $go"; return 1; }
      tok="$busy"
    elif grep -qF 'fmt.Fprintf(conn, "OK %s\n"' <<< "$l"; then tok="OK <uid>"
    else echo "FAIL: an unrecognised write to conn in handleResume: $l"; return 1
    fi
    toks="$toks$tok"$'\n'
  done <<< "$lines"
  toks=$(printf '%s' "$toks" | sort -u)
  n=$(printf '%s\n' "$toks" | grep -c . || true)
  [ "$n" -ge 5 ] || { echo "FAIL: control: only $n distinct handleResume replies found (want >= 5)"; return 1; }
  grep -qxF 'ERR-WORKER-BUSY' <<< "$toks" || { echo "FAIL: control: ERR-WORKER-BUSY is not among the handleResume replies"; return 1; }
  args=()
  while IFS= read -r t; do
    case "$t" in
      NONE) want=GONE ;; WRONGPASS) want=WRONG ;; NEEDKEY) want=NEEDKEY ;; ERR-RESTORE) want=RESTORE_FAILED ;;
      ERR-WORKER-BUSY) want=RETRY ;; ERR-NOTMPFS) want=NOTMPFS ;; "OK <uid>") want=SWITCH ;;
      *) echo "FAIL: handleResume answers \"$t\", which the suite's table does not know -- teach ResumeReply (and this table) first"; return 1 ;;
    esac
    if [ "$t" = "OK <uid>" ]; then args+=("OK 11"); else args+=("$t"); fi
  done <<< "$toks"
  out=$(bash "$RUN" "$pj" "$W" --kinds "${args[@]}") || return $?
  while IFS= read -r t; do
    case "$t" in
      NONE) want=GONE ;; WRONGPASS) want=WRONG ;; NEEDKEY) want=NEEDKEY ;; ERR-RESTORE) want=RESTORE_FAILED ;;
      ERR-WORKER-BUSY) want=RETRY ;; ERR-NOTMPFS) want=NOTMPFS ;; "OK <uid>") want=$'SWITCH\t11'; t="OK 11" ;;
    esac
    got=$(printf '%s\n' "$out" | awk -F'\t' -v t="$t" '$1==t{ $1=""; sub(/^\t/,""); print; exit }' OFS='\t')
    got=${got#$'\t'}
    if [ "$got" = "$want" ]; then echo "  ok   handleResume reply \"$t\" -> ${want//$'\t'/ }"
    else echo "FAIL: handleResume reply \"$t\": want ${want//$'\t'/ }, ResumeReply gives \"${got//$'\t'/ }\""; return 1; fi
  done <<< "$toks"
  return 0
}

# suite <ChooserActivity.java> <ResumeReply.java> <main.go> -> 0 pass, 1 a case, check or pin failed, >=2 broken
suite() {
  pins "$1" || return 1
  bash "$RUN" "$2" "$W" || return $?
  cross "$2" "$3" || return $?
}

echo "== $SRC"
suite "$SRC" "$PARSE" "$GO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour, the cross-side check or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: parse|activity|go> <perl-expr>
mut() {
  local d m rc a p g src; d=$(mktemp -d -p "$W"); a="$SRC"; p="$PARSE"; g="$GO"
  case "$2" in
    parse) m="$d/ResumeReply.java"; p="$m"; src="$PARSE" ;;
    activity) m="$d/ChooserActivity.java"; a="$m"; src="$SRC" ;;
    *) m="$d/main.go"; g="$m"; src="$GO" ;;
  esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$p" "$g" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
T='final String t = reply == null \? "" : reply\.trim\(\);\n'
mut "R1 every ERR- code maps to WRONG"        parse    "s/($T)/\$1        if (t.startsWith(\"ERR-\")) return new Verdict(WRONG, -1);\n/" || fails=$((fails+1))
mut "R2 an empty reply maps to WRONG"         parse    "s/($T)/\$1        if (t.isEmpty()) return new Verdict(WRONG, -1);\n/" || fails=$((fails+1))
mut "R3 the uid test > 0 made >= 0"           parse    's/if \(uid > 0\)/if (uid >= 0)/' || fails=$((fails+1))
mut "R4 the trim dropped"                     parse    's/reply == null \? "" : reply\.trim\(\)/reply == null ? "" : reply/' || fails=$((fails+1))
mut "R5 WRONGPASS matched by startsWith"      parse    's/t\.equals\("WRONGPASS"\)/t.startsWith("WRONGPASS")/' || fails=$((fails+1))
mut "R6 handleResume gains an unknown code"   go       's/(\n(\t+)fmt\.Fprint\(conn, "ERR-RESTORE\\n"\)\n)/$1$2fmt.Fprint(conn, "ERR-NEWCODE\\n")\n/' || fails=$((fails+1))
mut "R7 resume()'s WRONG arm also takes RETRY" activity 's/else if \(v\.kind == ResumeReply\.WRONG\) \{/else if (v.kind == ResumeReply.WRONG || v.kind == ResumeReply.RETRY) {/' || fails=$((fails+1))
mut "R8 NOTMPFS mapped to WRONG"            parse    's/return new Verdict\(NOTMPFS, -1\)/return new Verdict(WRONG, -1)/' || fails=$((fails+1))
mut "R9 the ERR-NOTMPFS mapping removed"      parse    's/        if \(t\.equals\("ERR-NOTMPFS"\)\) return new Verdict\(NOTMPFS, -1\);\n//' || fails=$((fails+1))
mut "R10 resume()'s NOTMPFS arm removed"      activity 's/                    else if \(v\.kind == ResumeReply\.NOTMPFS\) \{.*?\n                    \}\n//s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
