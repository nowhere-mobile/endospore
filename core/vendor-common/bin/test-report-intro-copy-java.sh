#!/usr/bin/env bash
# test-report-intro-copy-java.sh [--mutate] -- the two issue reporters' intros, run under javac (NWP-20261118-18).
#
# WHY THIS IS COMMITTED. Backlog row: "The phone's two issue reporters lack `/support`'s warning never to send a
# profile name or passphrase, though their note is free text". Profile › Report an issue said the passphrase is removed
# before anything is sent, but the note is free text and the agent's handleReportIssue redacts only the live profile
# name and generic patterns in it ("" at the gate), so a passphrase typed into the note is sent. ReportIntroCopy (pure,
# java.lang only) holds both intros; it is compiled here with its cases: (a) both intros end with /support's live
# "Never send us your profile name or passphrase.", and no sentence of the Profile intro before it names a passphrase;
# (b) showReportIssue sets its intro from ReportIntroCopy.PROFILE and buildReportScreen from ReportIntroCopy.GATE, and
# neither body holds the old inline literal (comments stripped first).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-report-intro-copy-java.sh            # the cases (a), pin (b)
#   bash test-report-intro-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/ReportIntroCopy.java"
PROFILE_SCREEN="$SRC/ProfileActivity.java"
GATE_SCREEN="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/report-intro/ReportIntroCopyCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl to strip comments, and there is none" >&2; exit 2; }

# suite <ReportIntroCopy.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  ReportIntroCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/ReportIntroCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ReportIntroCopyCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || { rm -rf "$d"; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ReportIntroCopyCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# body <file> <signature-regex> -> the method from its signature to the first "    }" line, with // and /* */
# comments removed (string and char literals are kept whole, so a "//" inside a string is not taken for a comment).
body() {
  local f="$1" sig="$2"
  awk -v sig="$sig" '$0 ~ sig { on = 1 } on { print } on && /^    }$/ { exit }' "$f" \
    | perl -0777 -pe 's{("(?:\\.|[^"\\\n])*"|'\''(?:\\.|[^'\''\\\n])*'\'')|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse'
}

# source_checks <ProfileActivity.java> <ChooserActivity.java> -> pin (b).
source_checks() {
  local pf="$1" gf="$2" pb gb n bad=0
  pb=$(body "$pf" 'private void showReportIssue[(][)]')
  [ -n "$pb" ] || { echo "  FAIL  showReportIssue not found in $pf" >&2; return 1; }
  gb=$(body "$gf" 'private View buildReportScreen[(][)]')
  [ -n "$gb" ] || { echo "  FAIL  buildReportScreen not found in $gf" >&2; return 1; }

  n=$(printf '%s\n' "$pb" | awk '/explain\.setText\(ReportIntroCopy\.PROFILE\);/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  showReportIssue does not set explain from ReportIntroCopy.PROFILE (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$pb" | awk '/explain\.setText\(/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  showReportIssue sets explain's text $n times, want 1" >&2; bad=1; }
  n=$(printf '%s\n' "$pb" | grep -cE '"[^"]*removed[^"]*"')
  [ "$n" -eq 0 ] || { echo "  FAIL  showReportIssue holds a string literal containing \"removed\" (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$pb" | grep -cE 'This sends your device model|could identify you are removed|passphrase, passwords')
  [ "$n" -eq 0 ] || { echo "  FAIL  showReportIssue still holds the old intro literal (found $n)" >&2; bad=1; }

  n=$(printf '%s\n' "$gb" | awk '/sub\.setText\(ReportIntroCopy\.GATE\);/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  buildReportScreen does not set sub from ReportIntroCopy.GATE (found $n)" >&2; bad=1; }
  n=$(printf '%s\n' "$gb" | awk '/sub\.setText\(/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  buildReportScreen sets sub's text $n times, want 1" >&2; bad=1; }
  n=$(printf '%s\n' "$gb" | grep -cE 'Sends scrubbed device diagnostics|personal details in the note')
  [ "$n" -eq 0 ] || { echo "  FAIL  buildReportScreen still holds the old intro literal (found $n)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_checks "$PROFILE_SCREEN" "$GATE_SCREEN" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates ReportIntroCopy.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ReportIntroCopy.java"
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
muts() { # muts <P|G> <label> <perl-expr>   (mutates a copy of ProfileActivity.java or ChooserActivity.java; pin (b) must fail)
  local which="$1" label="$2" expr="$3" d orig c rc
  d=$(mktemp -d -p "$W") || return 1
  if [ "$which" = P ]; then orig="$PROFILE_SCREEN"; else orig="$GATE_SCREEN"; fi
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$which" = P ]; then source_checks "$c" "$GATE_SCREEN" >/dev/null 2>&1; rc=$?
  else source_checks "$PROFILE_SCREEN" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; return 1; fi
  echo "  convicted $label"
}
fails=0
mut "M1 NEVER_SEND dropped from PROFILE" \
  's/(diagnostics\. You can review exactly what.s sent first\.) " \+ NEVER_SEND;/$1";/' || fails=$((fails+1))
mut "M2 NEVER_SEND dropped from GATE" \
  's/(Don.t put personal details in the "\n\s*\+ "note\.) " \+ NEVER_SEND;/$1";/' || fails=$((fails+1))
mut "M3 \"your passphrase, \" put back into PROFILE" \
  's/(Before anything is sent, )"\n(\s*)\+ "passwords,/$1your passphrase, "\n$2+ "passwords,/' || fails=$((fails+1))
mut "M4 NEVER_SEND reworded" \
  's/NEVER_SEND = "Never send us your profile name or passphrase\.";/NEVER_SEND = "Never send us your passphrase.";/' \
  || fails=$((fails+1))
muts P "M5 showReportIssue back to the old inline literal" \
  's/explain\.setText\(ReportIntroCopy\.PROFILE\);/explain.setText("This sends your device model, OS version, and a recent tail of app diagnostics so support "\n                + "can look into a problem. It\x27s anonymous \xe2\x80\x94 there\x27s no account. Before anything is sent, your "\n                + "passphrase, passwords, phone numbers, contacts, and anything that could identify you are removed. "\n                + "You can review exactly what\x27s sent first.");/' \
  || fails=$((fails+1))
muts G "M6 buildReportScreen back to its old literal" \
  's/sub\.setText\(ReportIntroCopy\.GATE\);/sub.setText("Sends scrubbed device diagnostics (update, setup and system logs) anonymously to support. "\n                + "Profile data and sign-in history are never included. Don\x27t put personal details in the note.");/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
