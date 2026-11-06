#!/usr/bin/env bash
# test-session-screen-timeout-java.sh [--mutate] -- a new session's 1 min screen-off timeout, under javac
# (NWP-20261113-13).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (Q073, 2026-10-20) decided a new session's screen goes off after
# 1 min, AOSP's own default, whatever the platform or an overlay would give the new user. SessionScreenTimeout.java is
# pure java.lang and is compiled as-is with core/chooser/tests/session-screen-timeout/SessionScreenTimeoutCases.java;
# that directory's run.sh then PINS the wiring the cases cannot see: roamLogin's tail (sign-in and create) calls
# ensureSessionScreenTimeout(uid) exactly once, after prepRoamedUser(uid) and before applyRoamedPrefs() (so the user's
# own value, which the Q012 capture will apply there, wins), and the method writes NEW_SESSION_MS into THAT user's
# resolver (createContextAsUser), behind needsWrite, on the caller's thread, catching Throwable.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-session-screen-timeout-java.sh            # the cases and the pins
#   bash test-session-screen-timeout-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/SessionScreenTimeout.java"
RUN="$root/core/chooser/tests/session-screen-timeout/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

echo "== $ACT"
bash "$RUN" "$SRCDIR" "$W" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/SessionScreenTimeout.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if cmp -s "$c" "$CLS" && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  bash "$RUN" "$d" "$W" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 NEW_SESSION_MS 30_000' cls 's/NEW_SESSION_MS = 60_000/NEW_SESSION_MS = 30_000/'
mut 'M2 needsWrite returns false' cls 's/return current != NEW_SESSION_MS;/return false;/'
mut 'M3 call moved after applyRoamedPrefs()' act 's/^([ \t]*ensureSessionScreenTimeout\(uid\);[^\n]*\n)((?:.*\n)*?)([ \t]*applyRoamedPrefs\(\);[^\n]*\n)/$2$3$1/m'
mut 'M4 call removed' act 's/^[ \t]*ensureSessionScreenTimeout\(uid\);[^\n]*\n//m'
mut "M5 the gate's resolver (no createContextAsUser)" act 's/(private void ensureSessionScreenTimeout\(int uid\).*?)createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\.getContentResolver\(\)/$1getContentResolver()/s'
mut 'M6 call moved before prepRoamedUser(uid)' act 's/^([ \t]*prepRoamedUser\(uid\);[^\n]*\n)([ \t]*ensureSessionScreenTimeout\(uid\);[^\n]*\n)/$2$1/m'
mut 'M7 also called from a cold-lock resume()' act 's/(private void resume\(final String pass, final boolean keyAlreadyAsserted\) \{\n)/$1        ensureSessionScreenTimeout(coldUid);\n/'
mut 'M8 the write put on its own Thread' act 's/(private void ensureSessionScreenTimeout\(int uid\) \{\n)(.*?\n    \}\n)/$1        new Thread(() -> {\n$2        }).start();\n    }\n/s'
mut 'M9 the catch dropped' act 's/(private void ensureSessionScreenTimeout\(int uid\).*?)catch \(Throwable t\)/$1catch (RuntimeException t)/s'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
