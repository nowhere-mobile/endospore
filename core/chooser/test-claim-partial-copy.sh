#!/usr/bin/env bash
# test-claim-partial-copy.sh [--mutate] -- what Add credits says when a CLAIM drains only part of a code (NWP-20261201-26).
#
# h60 #15 (docs/product-decisions.md, 2026-11-06): the agent keeps such a code in pending_claims and answers
# PARTIAL <n>[ UNSAVED]. ProfileActivity.addCreditsScreen read every reply that does not start with OK as a failure,
# so it said "Couldn't redeem that code" about a code that was part redeemed. Two legs, and both always run:
# claimPartialMessage is EXTRACTED verbatim (brace-matched) from the shipped source and RUN under a real JVM, and the
# PARTIAL branch of addCreditsScreen, which needs the Android classes, is read from the source with comments removed.
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-claim-partial-copy.sh            # the line, byte-pinned, and the branch
#   bash test-claim-partial-copy.sh --mutate   # ... plus mutants, each CONVICTED by the assertion it names
set -uo pipefail

PROFILE="$(cd "$(dirname "$0")" && pwd)/src/com/nowhere/chooser/ProfileActivity.java"
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
  echo "test-claim-partial-copy: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

extract() { # extract <file> <signature-fragment> -- the member, brace-matched
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED\n'); sys.exit(1)
PY
}

cat > "$W/tool.py" <<'PY'
# tool.py check <ProfileActivity.java>           the source assertions; 0 pass, 1 fail
# tool.py mutate <id> <in> <out>                 write one mutant; non-zero when its target text is absent
import io, re, sys

PARTIAL_IF = 'if (r.startsWith("PARTIAL "))'
OK_IF = 'if (!r.startsWith("OK"))'
MEMBER = 'static String claimPartialMessage(String r)'
SCREEN = 'void addCreditsScreen('

def read(path):
    return io.open(path, encoding='utf-8').read()

def code_only(s):
    # Literals stay and comments go: a comment naming BACKUP must not fail the branch, and a commented-out
    # codeF.setEnabled(true) must not pass it.
    keep = r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])\''
    def repl(m):
        return m.group(0) if m.group(0)[0] in '"\'' else ''
    return re.sub(keep + r'|//[^\n]*|/\*.*?\*/', repl, s, flags=re.S)

def span(s, start):
    # (start, the index past the brace that closes the first block at or after start)
    j = s.index('{', start); depth = 0
    for k in range(j, len(s)):
        if s[k] == '{': depth += 1
        elif s[k] == '}':
            depth -= 1
            if depth == 0:
                return start, k + 1
    raise ValueError('unbalanced')

def check(path):
    fails = 0
    def say(name, good):
        nonlocal fails
        print(('  PASS  ' if good else '  FAIL  ') + name)
        if not good: fails += 1
    code = code_only(read(path))
    body = block = ''
    i = code.find(SCREEN)
    if i >= 0:
        a, b = span(code, i)
        body = code[a:b]
    p = body.find('startsWith("PARTIAL')
    o = body.find(OK_IF)
    if p >= 0:
        a, b = span(body, p)
        block = body[a:b]
    say('PARTIAL test precedes the OK test', 0 <= p < o)
    say('branch calls claimPartialMessage', 'claimPartialMessage(r)' in block)
    for field in ('codeF', 'add', 'convertRb', 'keepRb'):
        say('branch re-enables ' + field, field + '.setEnabled(true);' in block)
    say('branch holds no PROMOTE2', p >= 0 and 'PROMOTE2' not in block)
    say('branch holds no BACKUP', p >= 0 and 'BACKUP' not in block)
    say('branch shows the line in ACCENT', 'msg.setTextColor(ACCENT);' in block
        and 'StatusLine.error' not in block and 'MUTED' not in block)
    say('branch returns', 'return;' in block)
    say('branch shows no Done', p >= 0 and '"Done"' not in block)
    return 1 if fails else 0

def within(s, bounds, old, new):
    a, b = bounds
    part = s[a:b]
    if old not in part:
        raise SystemExit('target absent: ' + old)
    return s[:a] + part.replace(old, new, 1) + s[b:]

def mutate(mid, src):
    member = span(src, src.index(MEMBER)) if MEMBER in src else None
    block = span(src, src.index(PARTIAL_IF)) if PARTIAL_IF in src else None
    if member is None or block is None:
        raise SystemExit('the member or the branch is absent')
    if mid == 'M1': return within(src, member, '!r.startsWith("PARTIAL ")', 'true')
    if mid == 'M2': return within(src, member, '"PARTIAL "', '"OK"')
    if mid == 'M3': return within(src, member, 'return "Only part', 'return r.substring(8).trim() + " Only part')
    if mid == 'M4':
        a, b = block
        moved = src[a:b]
        rest = src[:a] + src[b:].lstrip()
        _, end = span(rest, rest.index(OK_IF))
        return rest[:end] + '\n' + moved + rest[end:]
    if mid == 'M5': return within(src, block, 'return;', 'sendDaemon("PROMOTE2\\n"); return;')
    if mid == 'M6': return within(src, block, 'codeF.setEnabled(true);', '')
    if mid == 'M7': return within(src, block, 'return;', '')
    if mid == 'M8': return within(src, block, 'msg.setText(claimPartialMessage(r));', 'StatusLine.error(msg, claimPartialMessage(r));')
    if mid == 'M9': return within(src, block, 'return;', 'add.setText("Done"); return;')
    if mid == 'M10': return within(src, block, 'return;', 'sendDaemon("BACKUP\\n"); return;')
    raise SystemExit('unknown mutant ' + mid)

if sys.argv[1] == 'check':
    sys.exit(check(sys.argv[2]))
out = mutate(sys.argv[2], read(sys.argv[3]))
io.open(sys.argv[4], 'w', encoding='utf-8').write(out)
PY

java_leg() { # java_leg <ProfileActivity.java> -> 0 pass, 1 fail, 3 extraction failed, 4 compile failed
  rm -f "$W/ClaimPartial.java" "$W"/*.class
  local body
  body=$(extract "$1" 'static String claimPartialMessage(String r)') || { echo "EXTRACTION FAILED: no Java case can pass"; return 3; }
  {
    echo 'final class Lifted {'
    echo "$body"
    echo '}'
    cat <<'JAVA'
public class ClaimPartial {
  static final String LINE = "Only part of this code was redeemed. The rest is still on the code — redeem it again to add it.";
  static int fails = 0;
  static void say(String what, boolean good, String detail) {
    if (good) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static void none(String what, String reply) {
    String got = Lifted.claimPartialMessage(reply);
    say(what, got == null, "got \"" + got + "\", want null");
  }
  public static void main(String[] a) {
    String full = Lifted.claimPartialMessage("PARTIAL 3");
    String unsaved = Lifted.claimPartialMessage("PARTIAL 3 UNSAVED");
    say("PARTIAL 3 -> the line", LINE.equals(full), "got \"" + full + "\"");
    say("PARTIAL 3 UNSAVED -> the line", LINE.equals(unsaved), "got \"" + unsaved + "\"");
    none("OK 3 -> null", "OK 3");
    none("OK 3 UNSAVED -> null", "OK 3 UNSAVED");
    none("ERR -> null", "ERR");
    none("ERR-NOCODE -> null", "ERR-NOCODE");
    none("empty -> null", "");
    none("null -> null", null);
    none("PARTIAL with no count -> null", "PARTIAL");
    boolean noDigit = full != null && unsaved != null;
    boolean noWord = noDigit;
    for (String s : new String[] { full, unsaved }) {
      if (s == null) continue;
      if (s.matches("(?s).*\\d.*")) noDigit = false;
      String l = s.toLowerCase();
      for (String w : new String[] { "token", "gb-month", "lost", "automatic", "later" }) {
        if (l.contains(w)) noWord = false;
      }
    }
    say("no digit in the line", noDigit, "got \"" + full + "\" and \"" + unsaved + "\"");
    say("no forbidden word in the line", noWord, "got \"" + full + "\" and \"" + unsaved + "\"");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$W/ClaimPartial.java"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -nowarn -encoding UTF-8 -d "$W" "$W/ClaimPartial.java" 2>"$W/javac.err" || { head -5 "$W/javac.err"; return 4; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$W" ClaimPartial
}

legs() { # legs <ProfileActivity.java> -> 0 pass, 1 a check failed, 3 extraction failed, 4 compile failed
  local jrc prc
  java_leg "$1"; jrc=$?
  python3 "$W/tool.py" check "$1"; prc=$?
  [ "$jrc" -ge 3 ] && return "$jrc"
  [ "$jrc" = 0 ] && [ "$prc" = 0 ]
}

legs "$PROFILE"; RC=$?
if [ "$RC" -ge 3 ]; then echo "suite FAILED: the Java leg did not run"; exit 2; fi
[ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted by the assertion it names) =="
MRC=0
mutant() { # mutant <id> <what> <the assertion that must convict it>
  local m="$W/mut.java" out rc=0
  if ! python3 "$W/tool.py" mutate "$1" "$PROFILE" "$m" || cmp -s "$PROFILE" "$m"; then
    printf '  ⚠ NOT APPLIED %s %s\n' "$1" "$2"; MRC=1; return
  fi
  out=$(legs "$m" 2>&1); rc=$?
  case "$rc" in
    0) printf '  ⚠ SURVIVED  %s %s\n' "$1" "$2"; MRC=1 ;;
    1) case "$out" in
         *"  FAIL  $3"*) printf '  convicted   %s %s [%s]\n' "$1" "$2" "$3" ;;
         *) printf '  ⚠ NOT CONVICTED BY [%s]  %s %s\n' "$3" "$1" "$2"; MRC=1 ;;
       esac ;;
    *) printf '  ⚠ DID NOT BUILD %s %s\n' "$1" "$2"; MRC=1 ;;
  esac
}
mutant M1  "claimPartialMessage returns null for PARTIAL" "PARTIAL 3 -> the line"
mutant M2  "the member matches OK instead"                "OK 3 -> null"
mutant M3  "the line carries the count"                   "no digit in the line"
mutant M4  "the branch moves after the OK check"          "PARTIAL test precedes the OK test"
mutant M5  "the branch calls PROMOTE2"                    "branch holds no PROMOTE2"
mutant M6  "the branch drops the codeF re-enable"         "branch re-enables codeF"
mutant M7  "the branch loses its return"                  "branch returns"
mutant M8  "the branch shows the error style"             "branch shows the line in ACCENT"
mutant M9  "the branch shows Done"                        "branch shows no Done"
mutant M10 "the branch sends BACKUP"                      "branch holds no BACKUP"
echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
