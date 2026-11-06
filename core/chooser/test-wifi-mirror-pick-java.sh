#!/usr/bin/env bash
# test-wifi-mirror-pick-java.sh [--mutate] -- NWP-20261120-14: the Wi-Fi mirror sends the connected network first, within
# its cap of 16. Runs core/chooser/tests/wifi-mirror-pick: WifiMirrorPick (the order WifiMirror.capture sends) compiled
# alone and EXECUTED, capture checked by text, and WifiMirrorPick.MAX checked against handleWifiMirror's bound in
# core/agent/main.go (read from the file, never hard-coded).
#
# WHY THIS IS COMMITTED. capture used to send the first 16 saved networks in framework order (WifiConfigManager's, not
# the user's). With more than 16 saved, the network the session was connected to could be left off, the gate adopted the
# other 16, and the switch to user 0 dropped Wi-Fi at sign-out or cold lock -- the drop #98 exists to prevent. The cap
# stays 16: the gate adopts every mirrored network into its phone-wide store (amnesia finding #9;
# docs/wifi-retention-spec.md §7.2 item 7).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE (a copy that no longer
# compiles, or whose edit does not apply, convicts nothing and is reported as a failure).
#
#   bash test-wifi-mirror-pick-java.sh            # the cases
#   bash test-wifi-mirror-pick-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CH="$ROOT/core/chooser"
GO="$ROOT/core/agent/main.go"
RUN="$CH/tests/wifi-mirror-pick/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-wifi-mirror-pick-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
WMP_TMP=$(mktemp -d -p "$W") || exit 2
WMP_TMP=$WMP_TMP bash "$RUN" "$CH" "$GO"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  mutate(){ # mutate <label> <case it must fail> <file: Pick|Mirror|main.go> <sed script>
    local label=$1 want=$2 which=$3 script=$4
    local d; d=$(mktemp -d -p "$W") || { no "MUTATION BROKEN (mktemp): $label"; return; }
    mkdir -p "$d/c/src/com/nowhere/chooser" "$d/tmp"
    cp "$CH/src/com/nowhere/chooser/WifiMirrorPick.java" "$CH/src/com/nowhere/chooser/WifiMirror.java" \
      "$d/c/src/com/nowhere/chooser/"
    cp "$GO" "$d/main.go"
    local f orig
    case "$which" in
      Pick)    f="$d/c/src/com/nowhere/chooser/WifiMirrorPick.java"; orig="$CH/src/com/nowhere/chooser/WifiMirrorPick.java" ;;
      Mirror)  f="$d/c/src/com/nowhere/chooser/WifiMirror.java"; orig="$CH/src/com/nowhere/chooser/WifiMirror.java" ;;
      main.go) f="$d/main.go"; orig="$GO" ;;
    esac
    if ! sed -i "$script" "$f" 2>/dev/null; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$f" "$orig"; then no "MUTATION INERT: $label"; return; fi
    local out r
    out=$(WMP_TMP="$d/tmp" bash "$RUN" "$d/c" "$d/main.go" 2>&1); r=$?
    case "$r" in
      1) case "$out" in
           *"  FAIL  $want"*) ok "convicted: $label (by \"$want\")" ;;
           *) no "MUTATION convicted by the WRONG case: $label -- expected \"$want\"" ;;
         esac ;;
      0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
    esac
  }
  mutate "order() ignores currentAt" "current late is kept first" Pick \
    's/^        if (lines == null) return out;$/        if (lines == null) return out;\n        currentAt = -1;/'
  mutate "order() puts the current line LAST" "current early moves first" Pick \
    '/^        if (currentAt != -1) out.add(lines.get(currentAt));$/d; s/^        return out;$/        if (currentAt != -1) out.add(lines.get(currentAt));\n        return out;/'
  mutate "order() applies the cap before moving the current line" "current late is kept first" Pick \
    's/^        if (lines == null) return out;$/        if (lines == null) return out;\n        if (lines.size() > MAX) lines = lines.subList(0, MAX);/'
  mutate "MAX = 64" "WifiMirrorPick.MAX (64) is at most handleWifiMirror's bound" Pick \
    's/static final int MAX = 16;/static final int MAX = 64;/'
  mutate "capture keeps the >= 16 break" "capture has no numeric cap of its own" Mirror \
    's/^                lines.add(line);$/                lines.add(line);\n                if (lines.size() >= 16) break;/'
  mutate "main.go's bound changed to 8" "WifiMirrorPick.MAX (16) is at most handleWifiMirror's bound (8)" main.go \
    's/n <= 0 || n > 32 {/n <= 0 || n > 8 {/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
