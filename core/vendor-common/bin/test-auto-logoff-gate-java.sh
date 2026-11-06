#!/usr/bin/env bash
# test-auto-logoff-gate-java.sh [--mutate] -- ProfileActivity honours its `auto` extra only from the .AutoLogoff alias
# (NWP-20261106-03).
#
# WHY THIS IS COMMITTED. ProfileActivity is exported (the launcher drawer's Profile entry), and its onCreate used to run
# doLogoff() for an `auto` extra from ANY caller: an app in a session could sign the user out, unasked, as often as it
# liked. The L4 backstop (five wrong unlocks) now starts the non-exported `.AutoLogoff` activity-alias, and onCreate
# honours the extra only when the launched component is that alias (AutoLogoffGate, java.lang only, compiled here with
# its cases). Source and XML checks pin the four places that make it hold: the manifest, AdminReceiver, onCreate and
# onNewIntent. NWP-20261113-02: with the Profile screen the session's top activity, the alias start was
# START_DELIVERED_TO_TOP (result code=3, lynx 2026102201): it reached onNewIntent, not onCreate, and nothing signed out.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-auto-logoff-gate-java.sh            # the cases and the source/XML checks
#   bash test-auto-logoff-gate-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/AutoLogoffGate.java"
RECEIVER="$SRC/AdminReceiver.java"
PROFILE="$SRC/ProfileActivity.java"
MANIFEST="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/auto-logoff-gate/AutoLogoffGateCases.java"
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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 (the manifest check parses XML)" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <AutoLogoffGate.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  AutoLogoffGate.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/AutoLogoffGate.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/AutoLogoffGateCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AutoLogoffGateCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# xmlcheck <AndroidManifest.xml> -> 0 when the alias is non-exported on ProfileActivity and ProfileActivity is exported.
xmlcheck() {
  python3 -I - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
A = "{http://schemas.android.com/apk/res/android}"
try:
    app = ET.parse(sys.argv[1]).getroot().find("application")
except Exception as e:
    print("  FAIL  (X) manifest does not parse: %s" % e); sys.exit(1)
bad = 0
aliases = [a for a in app.findall("activity-alias") if a.get(A + "name") == ".AutoLogoff"]
if len(aliases) != 1:
    print("  FAIL  (X) want exactly one .AutoLogoff alias, found %d" % len(aliases)); bad = 1
else:
    a = aliases[0]
    if a.get(A + "exported") != "false":
        print("  FAIL  (X) .AutoLogoff exported=%r, want 'false'" % a.get(A + "exported")); bad = 1
    if a.get(A + "targetActivity") != ".ProfileActivity":
        print("  FAIL  (X) .AutoLogoff targetActivity=%r" % a.get(A + "targetActivity")); bad = 1
    if a.find("intent-filter") is not None:
        print("  FAIL  (X) .AutoLogoff has an intent-filter"); bad = 1
p = [x for x in app.findall("activity") if x.get(A + "name") == ".ProfileActivity"]
if len(p) != 1 or p[0].get(A + "exported") != "true":
    print("  FAIL  (X) ProfileActivity must stay exported='true' (the launcher needs it)"); bad = 1
sys.exit(bad)
PY
}

# receiver <AdminReceiver.java> -> 0 when the backstop starts the alias by name.
receiver() {
  local f="$1" bad=0 c
  c=$(grep -c '"com.nowhere.chooser.AutoLogoff"' "$f")
  [ "$c" -ge 1 ] || { echo "  FAIL  (R) AdminReceiver does not name com.nowhere.chooser.AutoLogoff" >&2; bad=1; }
  c=$(grep -c 'new Intent(context, ProfileActivity.class)' "$f")
  [ "$c" -eq 0 ] || { echo "  FAIL  (R) AdminReceiver still starts ProfileActivity.class directly" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# oncreate <ProfileActivity.java> -> 0 when onCreate's auto condition is exactly the alias-gated line, followed by
# doLogoff(); return;. The whole line is pinned, not just the call: honoured(AutoLogoffGate.ALIAS, ...) compiles and
# would honour `auto` from any caller.
oncreate() {
  local f="$1" c
  local want='        if (getIntent() != null && AutoLogoffGate.honoured(getIntent().getComponent() == null ? null : getIntent().getComponent().getClassName(), getIntent().getBooleanExtra("auto", false))) {'
  c=$(grep -c 'AutoLogoffGate\.honoured(' "$f")
  [ "$c" -eq 2 ] || { echo "  FAIL  (O) want exactly two AutoLogoffGate.honoured( calls in ProfileActivity (onCreate and onNewIntent), found $c" >&2; return 1; }
  c=$(awk '/^    protected void onCreate\(Bundle b\) \{$/ { on = 1 } on && $0 !~ /^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f" | grep -cxF -- "$want")
  [ "$c" -eq 1 ] || { echo "  FAIL  (O) onCreate's auto condition is not exactly the alias-gated line (found $c)" >&2; return 1; }
  c=$(awk '/AutoLogoffGate\.honoured\(/ { getline a; getline b; print a b; exit }' "$f" | tr -s ' ')
  case "$c" in
    *"doLogoff();"*"return;"*) return 0 ;;
    *) echo "  FAIL  (O) the gate's condition is not followed by doLogoff(); return;" >&2; return 1 ;;
  esac
}

# newintent <ProfileActivity.java> -> 0 when onNewIntent re-reads the delivered intent through the same alias gate:
# super + setIntent, the loggingOff re-entry guard before the gate (a 6th or later wrong unlock during "Logging off..."
# is delivered here again and must not start a second sign-out), the exact alias-gated line, doLogoff(); return; right
# under it, and no doLogoff before it. NWP-20261113-02: with the Profile screen on top the alias start is
# DELIVERED_TO_TOP, so onCreate never runs.
newintent() {
  local f="$1" body c g q
  local guard='        if (loggingOff) return;'
  local want='        if (AutoLogoffGate.honoured(intent.getComponent() == null ? null : intent.getComponent().getClassName(), intent.getBooleanExtra("auto", false))) {'
  body=$(awk '/^    protected void onNewIntent\(Intent intent\) \{$/ { on = 1 } on && $0 !~ /^[ \t]*\/\// { print } on && /^    }$/ { exit }' "$f")
  [ -n "$body" ] || { echo "  FAIL  (N) ProfileActivity has no 'protected void onNewIntent(Intent intent) {'" >&2; return 1; }
  c=$(printf '%s\n' "$body" | grep -cxF -- '        super.onNewIntent(intent);')
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent does not call super.onNewIntent(intent); (found $c)" >&2; return 1; }
  c=$(printf '%s\n' "$body" | grep -cxF -- '        setIntent(intent);')
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent does not call setIntent(intent); (found $c)" >&2; return 1; }
  c=$(printf '%s\n' "$body" | grep -cxF -- "$want")
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent's auto condition is not exactly the alias-gated line (found $c)" >&2; return 1; }
  g=$(printf '%s\n' "$body" | grep -nxF -- "$want" | cut -d: -f1)
  c=$(printf '%s\n' "$body" | grep -cxF -- "$guard")
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent has no re-entry guard 'if (loggingOff) return;' line (found $c)" >&2; return 1; }
  q=$(printf '%s\n' "$body" | grep -nxF -- "$guard" | cut -d: -f1)
  [ "$q" -lt "$g" ] || { echo "  FAIL  (N) onNewIntent's re-entry guard is not before the alias-gated line" >&2; return 1; }
  c=$(printf '%s\n' "$body" | sed -n "$((g+1))p" | grep -cxF -- '            doLogoff();')
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent's gated line is not followed by doLogoff();" >&2; return 1; }
  c=$(printf '%s\n' "$body" | sed -n "$((g+2))p" | grep -cxF -- '            return;')
  [ "$c" -eq 1 ] || { echo "  FAIL  (N) onNewIntent's doLogoff(); is not followed by return;" >&2; return 1; }
  c=$(printf '%s\n' "$body" | awk -v g="$g" '/doLogoff/ && NR <= g { n++ } END { print n + 0 }')
  [ "$c" -eq 0 ] || { echo "  FAIL  (N) onNewIntent reaches doLogoff before the alias-gated line" >&2; return 1; }
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
fail=0
xmlcheck "$MANIFEST" || fail=1
receiver "$RECEIVER" || fail=1
oncreate "$PROFILE" || fail=1
newintent "$PROFILE" || fail=1
[ "$fail" -eq 0 ] || { echo "FAILED (source checks)"; exit 1; }
echo "source checks: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates AutoLogoffGate.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/AutoLogoffGate.java"
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
mutsrc() { # mutsrc <label> <manifest|receiver|profile|newintent> <perl-expr>   (the matching source check must fail)
  local d c rc f; d=$(mktemp -d -p "$W") || return 1
  case "$2" in manifest) f="$MANIFEST" ;; receiver) f="$RECEIVER" ;; *) f="$PROFILE" ;; esac
  c="$d/$(basename "$f")"
  cp "$f" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$f" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    manifest) xmlcheck "$c" >/dev/null 2>&1; rc=$? ;;
    receiver) receiver "$c" >/dev/null 2>&1; rc=$? ;;
    newintent) newintent "$c" >/dev/null 2>&1; rc=$? ;;
    *) oncreate "$c" >/dev/null 2>&1; rc=$? ;;
  esac
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "honoured ignores the class" 's/autoExtra && ALIAS\.equals\(launchedClass\)/autoExtra/' || fails=$((fails+1))
mutsrc "the alias exported=true" manifest 's/(android:name="\.AutoLogoff"[^>]*?android:exported=")false/$1true/s' || fails=$((fails+1))
mutsrc "AdminReceiver back to ProfileActivity.class" receiver 's/new Intent\(\)\s*\.setClassName\(context, "com\.nowhere\.chooser\.AutoLogoff"\)/new Intent(context, ProfileActivity.class)/s' || fails=$((fails+1))
mutsrc "onCreate without the gate call" profile 's/AutoLogoffGate\.honoured\(.*?\)\) \{/getIntent().getBooleanExtra("auto", false)) {/' || fails=$((fails+1))
mutsrc "honoured fed the alias constant" profile 's/AutoLogoffGate\.honoured\(getIntent\(\)\.getComponent\(\) == null \? null : getIntent\(\)\.getComponent\(\)\.getClassName\(\),/AutoLogoffGate.honoured(AutoLogoffGate.ALIAS,/' || fails=$((fails+1))
# NWP-20261113-02: onNewIntent's mutants target its `intent.` spelling; the two above target onCreate's getIntent().
mutsrc "onNewIntent override deleted" newintent 's/\n    \@Override\n    protected void onNewIntent\(Intent intent\) \{\n.*?\n    \}\n/\n/s' || fails=$((fails+1))
mutsrc "onNewIntent without the component check" newintent 's/AutoLogoffGate\.honoured\(intent\.getComponent\(\).*?\)\) \{/intent.getBooleanExtra("auto", false)) {/' || fails=$((fails+1))
mutsrc "onNewIntent signs out on any new intent" newintent 's/if \(AutoLogoffGate\.honoured\(intent\.[^\n]*\) \{/if (true) {/' || fails=$((fails+1))
mutsrc "onNewIntent's honoured fed the alias constant" newintent 's/AutoLogoffGate\.honoured\(intent\.getComponent\(\) == null \? null : intent\.getComponent\(\)\.getClassName\(\),/AutoLogoffGate.honoured(AutoLogoffGate.ALIAS,/' || fails=$((fails+1))
mutsrc "onNewIntent re-entry guard removed" newintent 's/(protected void onNewIntent\(Intent intent\) \{\n.*?)\n        if \(loggingOff\) return;\n/$1\n/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
