#!/usr/bin/env bash
# test-daemon-reply-java.sh [--mutate] -- NWP-20261011-63: a one-line daemon read of a multi-line reply is logged, not
# silent. Runs core/chooser/tests/daemon-reply under javac.
#
# WHY THIS IS COMMITTED. DaemonSocket.roundTrip (which ChooserActivity.sendDaemon delegates to) and
# ProfileActivity.sendDaemon read ONE reply line and drop the rest. That has shipped as a silent no-op twice (every SIM
# showing "not bound"; the #176 outbound lock). Both now ask DaemonSocket.moreBuffered after their readLine and log the
# request's VERB -- DaemonSocket.verbOf, never the rest of the request, whose later lines carry passphrases.
# core/chooser/tests/daemon-reply/run.sh lifts the two helpers out of the real DaemonSocket.java and runs Cases against
# them; the PINS below check that both readers call moreBuffered right after their readLine and log only verbOf(msg).
# The check is best-effort (see moreBuffered): a reply line written after the first one is read is still not seen.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. A suite that quietly passes because its tool is missing reads
# exactly like one that ran. javac comes from PATH, else from the build host's JDK below; the CI runner is the build
# VM, which has it. The version is printed first so the log proves which compiler ran.
#
#   bash test-daemon-reply-java.sh            # the pins and the cases
#   bash test-daemon-reply-java.sh --mutate   # ... plus broken copies of the sources that must each FAIL the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DS="$root/core/chooser/src/com/nowhere/chooser/DaemonSocket.java"
PA="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
RUN="$root/core/chooser/tests/daemon-reply/run.sh"
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
[ -f "$DS" ] && [ -f "$PA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $DS, $PA or $RUN" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: the pins need perl, and there is none -- refusing to report" >&2; exit 2; }

# suite <DaemonSocket.java> <ProfileActivity.java> -> 0 pass, 1 a pin or a case failed, 2 a helper did not extract,
# 3 the lifted class did not compile. Only 1 may convict a mutant; 2 and 3 prove nothing about the logic.
suite() {
  local ds="$1" pa="$2"
  # PIN 1: roundTrip asks moreBuffered on the very next statement after its readLine, and logs only verbOf(msg).
  # Multi-line and anchored on the method's signature, so the order and the method are part of the match.
  perl -0ne 'exit(/static String roundTrip\(String msg, int readCapMs\) \{.*?String line = br\.readLine\(\);\n\s*if \(moreBuffered\(br\)\)[^\n]*\n\s*android\.util\.Log\.e\("NowhereChooser", "roundTrip\(" \+ verbOf\(msg\) \+ "\): the reply has more than one line "\n\s*\+ "and only the first was read -- use DaemonSocket\.roundTripLines"\);\n\s*return line == null/s ? 0 : 1)' "$ds" || {
    echo "  PIN   DaemonSocket.roundTrip no longer logs a multi-line reply by verb after its readLine" >&2; return 1; }
  # PIN 2: ProfileActivity.sendDaemon (its own socket code) does the same through the DaemonSocket helpers.
  perl -0ne 'exit(/private String sendDaemon\(String msg\) \{.*?String line = br\.readLine\(\);\n\s*if \(DaemonSocket\.moreBuffered\(br\)\)[^\n]*\n\s*android\.util\.Log\.e\("NowhereChooser", "sendDaemon\(" \+ DaemonSocket\.verbOf\(msg\) \+ "\): the reply has more "\n\s*\+ "than one line and only the first was read -- use DaemonSocket\.roundTripLines"\);\n\s*s\.close\(\);/s ? 0 : 1)' "$pa" || {
    echo "  PIN   ProfileActivity.sendDaemon no longer logs a multi-line reply by verb after its readLine" >&2; return 1; }
  # PIN 3: ChooserActivity.sendDaemon still delegates to roundTrip, so PIN 1 covers it.
  grep -qF 'return DaemonSocket.roundTrip(msg, 90000);' "$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java" || {
    echo "  PIN   ChooserActivity.sendDaemon no longer delegates to DaemonSocket.roundTrip" >&2; return 1; }
  bash "$RUN" "$ds"
}

echo "== $DS + $PA"
suite "$DS" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <ds|pa> <perl-expr>
  local d m rc src; d=$(mktemp -d)
  case "$2" in ds) src="$DS" ;; pa) src="$PA" ;; *) echo "  ERROR     $1 -- bad target $2"; rm -rf "$d"; return 1 ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = ds ]; then suite "$m" "$PA" >/dev/null 2>&1; else suite "$DS" "$m" >/dev/null 2>&1; fi; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 verbOf returns the whole request (logs the passphrase)" ds 's/return msg == null \? "\?" : msg\.split\("\\n", 2\)\[0\]\.trim\(\);/return msg == null ? "?" : msg;/' || fails=$((fails+1))
mut "M2 verbOf drops the trim"                ds 's/return msg == null \? "\?" : msg\.split\("\\n", 2\)\[0\]\.trim\(\);/return msg == null ? "?" : msg.split("\\n", 2)[0];/' || fails=$((fails+1))
mut "M3 verbOf of null is null"               ds 's/return msg == null \? "\?" :/return msg == null ? null :/' || fails=$((fails+1))
mut "M4 moreBuffered never fires"             ds 's/return br\.ready\(\);/return false;/' || fails=$((fails+1))
mut "M5 moreBuffered always fires"            ds 's/return br\.ready\(\);/return true;/' || fails=$((fails+1))
mut "M6 moreBuffered consumes the next line"  ds 's/return br\.ready\(\);/return br.readLine() != null;/' || fails=$((fails+1))
mut "M7 roundTrip skips the check"            ds 's/if \(moreBuffered\(br\)\) \/\//if (false) \/\//' || fails=$((fails+1))
mut "M8 roundTrip logs the whole request"     ds 's/"roundTrip\(" \+ verbOf\(msg\) \+/"roundTrip(" + msg +/' || fails=$((fails+1))
mut "M9 sendDaemon skips the check"           pa 's/if \(DaemonSocket\.moreBuffered\(br\)\)/if (false)/' || fails=$((fails+1))
mut "M10 sendDaemon logs the whole request"   pa 's/"sendDaemon\(" \+ DaemonSocket\.verbOf\(msg\) \+ "\): the reply/"sendDaemon(" + msg + "): the reply/' || fails=$((fails+1))
mut "M11 sendDaemon checks after closing"     pa 's/(\n(\s*)if \(DaemonSocket\.moreBuffered\(br\)\)[^\n]*\n[^\n]*\n[^\n]*\n)(\s*s\.close\(\);\n)/\n$3$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
