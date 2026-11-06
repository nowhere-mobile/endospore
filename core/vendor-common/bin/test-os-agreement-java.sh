#!/usr/bin/env bash
# test-os-agreement-java.sh [--mutate] -- the first-boot OS agreement screen, its DRAFT text and its one gate, under
# javac (NWP-20261114-11).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-24) builds the first-boot OS agreement screen now, with
# DRAFT text, on beta-ring images only, behind one gate whose flip waits for counsel. OsAgreement.java holds the gate
# (PRODUCTION_APPROVED, false), shouldShow(<GET-OS-AGREEMENT reply>), canContinue and the text; it is pure java,
# compiled as-is with OsAgreementCases by core/chooser/tests/os-agreement/run.sh. The cases check the gate is off, only
# an exact "draft" reply shows the screen, setup goes on only with both confirmations, the text is never styled as a
# licence and keeps to docs/privacy-claims.md §3, and the lost-passphrase acknowledgement names the passphrase, "no one"
# and Nowhere. The PINS below check the ChooserActivity wiring the cases cannot see: the first-run thread passes
# shouldShow of a GET-OS-AGREEMENT reply (and the marker) to launchFirstRun; launchFirstRun(true) shows the screen with
# the welcome as its next step, and launchFirstRun(false) is the welcome as before; the screen adds DRAFT_MARK while
# showsDraftMark(), builds two separate CheckBoxes, enables its one button only through canContinue on every toggle,
# writes the marker before it goes on, and has no other way out.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-os-agreement-java.sh            # the cases and the pins
#   bash test-os-agreement-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/OsAgreement.java"
RUN="$root/core/chooser/tests/os-agreement/run.sh"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# line_of <text> <fixed-string> -> "<count> <first line number>" of the lines holding the string (the string goes
# through the environment: awk -v would turn its \n into a newline)
line_of() {
  printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++; if (!first) first=NR } END { print n+0, first+0 }'
}

# one <text> <fixed-string> <pin> -> the line number of the one line holding the string, or a PIN failure (rc 1)
one() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  [ "$n" = 1 ] || { echo "  PIN $3 $n lines hold: $2 -- want 1" >&2; return 1; }
  echo "$l"
}

# none <text> <fixed-string> <pin> -> rc 1 when any line holds the string
none() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  [ "$n" = 0 ] || { echo "  PIN $3 $n lines hold: $2 -- want 0" >&2; return 1; }
}

# suite <ChooserActivity.java> <OsAgreement.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" rc src b lstore lhint lag lui lif lels lm lmark ladd lbody ltitle lg lok len lend lclick lchk
  local lset lnext n
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$RUN" ] || { echo "  FAIL missing $RUN" >&2; return 2; }
  TMPDIR="$W" JAVAC="$JAVAC" JAVA="$JAVA" bash "$RUN" "$cls"; rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; 3) echo "  FAIL the class did not compile" >&2; return 3 ;; *) return 2 ;; esac

  src=$(grep -v '^[[:space:]]*//' "$f")

  # P1 the first-run thread: inside the configured=no branch, after the done-first-run hint, one read of the ring
  # signal, given to shouldShow and ANDed with the marker; the next line hands it to launchFirstRun on the UI thread.
  lstore=$(one "$src" 'if (sendDaemonLines("GET-STORE\n").contains("configured=no")) {' P1) || return 1
  lhint=$(one "$src" 'if (firstRunDone()) runOnUiThread(this::showStoreHint);' P1) || return 1
  lag=$(one "$src" 'final boolean agreement = OsAgreement.shouldShow(sendDaemon("GET-OS-AGREEMENT\n")) && !osAgreementAccepted();' P1) || return 1
  lui=$(one "$src" 'runOnUiThread(() -> launchFirstRun(agreement));' P1) || return 1
  [ "$lhint" = $((lstore + 1)) ] && [ "$lag" -gt "$lhint" ] && [ "$lag" -le $((lhint + 2)) ] && [ "$lui" = $((lag + 1)) ] || {
    echo "  PIN P1 order: configured=no at $lstore, hint at $lhint, read at $lag, launch at $lui" >&2; return 1; }
  read -r n _ <<<"$(line_of "$src" 'GET-OS-AGREEMENT')"
  [ "$n" = 1 ] || { echo "  PIN P1 $n lines name GET-OS-AGREEMENT, want 1" >&2; return 1; }
  none "$src" 'launchFirstRun()' P1 || return 1

  # P2 launchFirstRun: the agreement branch shows the screen with the welcome as its next step; the other branch is
  # today's welcome, byte for byte.
  b=$(body "$f" 'private void launchFirstRun(boolean agreement) {')
  [ -n "$b" ] || { echo "  PIN P2 no launchFirstRun(boolean agreement) in $f" >&2; return 1; }
  lif=$(one "$b" '        if (agreement) setContentView(buildOsAgreementScreen(() -> setContentView(buildFirstRunWelcome())));' P2) || return 1
  lels=$(one "$b" '        else setContentView(buildFirstRunWelcome());' P2) || return 1
  [ "$lels" = $((lif + 1)) ] || { echo "  PIN P2 the else at $lels does not follow the agreement branch at $lif" >&2; return 1; }
  read -r n _ <<<"$(line_of "$b" 'setContentView(')"
  [ "$n" = 2 ] || { echo "  PIN P2 $n lines call setContentView( in launchFirstRun, want 2" >&2; return 1; }

  # The screen, without its comment lines.
  b=$(body "$f" 'private View buildOsAgreementScreen(Runnable next) {')
  [ -n "$b" ] || { echo "  PIN P3 no buildOsAgreementScreen(Runnable next) in $f" >&2; return 1; }
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//')

  # P3 the DRAFT mark: set and added inside `if (OsAgreement.showsDraftMark()) {`, before the title and the body.
  lm=$(one "$b" 'if (OsAgreement.showsDraftMark()) {' P3) || return 1
  read -r n _ <<<"$(line_of "$b" 'showsDraftMark()')"
  [ "$n" = 1 ] || { echo "  PIN P3 $n lines name showsDraftMark() in the screen, want 1" >&2; return 1; }
  lmark=$(one "$b" 'mark.setText(OsAgreement.DRAFT_MARK);' P3) || return 1
  read -r n _ <<<"$(line_of "$b" 'DRAFT_MARK')"
  [ "$n" = 1 ] || { echo "  PIN P3 $n lines name DRAFT_MARK in the screen, want 1" >&2; return 1; }
  ladd=$(one "$b" 'll.addView(mark, ' P3) || return 1
  ltitle=$(one "$b" 't.setText(OsAgreement.TITLE);' P3) || return 1
  lbody=$(one "$b" 'body.setText(OsAgreement.BODY);' P3) || return 1
  [ "$lmark" -gt "$lm" ] && [ "$lmark" -le $((lm + 3)) ] && [ "$ladd" -gt "$lmark" ] && [ "$ladd" -lt "$ltitle" ] \
    && [ "$ltitle" -lt "$lbody" ] || {
    echo "  PIN P3 order: showsDraftMark at $lm, mark at $lmark, added at $ladd, title at $ltitle, body at $lbody" >&2
    return 1; }
  one "$b" 'll.addView(t, ' P3 >/dev/null || return 1
  one "$b" 'll.addView(body, ' P3 >/dev/null || return 1

  # P4 two separate confirmations: two CheckBoxes, each with its own text and its own addView, after the body.
  read -r n _ <<<"$(line_of "$b" 'android.widget.CheckBox(')"
  [ "$n" = 2 ] || { echo "  PIN P4 $n lines build an android.widget.CheckBox, want 2" >&2; return 1; }
  one "$b" 'final android.widget.CheckBox agree = new android.widget.CheckBox(this);' P4 >/dev/null || return 1
  one "$b" 'final android.widget.CheckBox ack = new android.widget.CheckBox(this);' P4 >/dev/null || return 1
  one "$b" '        agree.setText(OsAgreement.AGREE);' P4 >/dev/null || return 1
  one "$b" '        ack.setText(OsAgreement.ACK);' P4 >/dev/null || return 1
  read -r n _ <<<"$(line_of "$b" 'OsAgreement.ACK')"
  [ "$n" = 1 ] || { echo "  PIN P4 $n lines name OsAgreement.ACK in the screen, want 1" >&2; return 1; }
  read -r n _ <<<"$(line_of "$b" 'OsAgreement.AGREE')"
  [ "$n" = 1 ] || { echo "  PIN P4 $n lines name OsAgreement.AGREE in the screen, want 1" >&2; return 1; }
  lag=$(one "$b" 'll.addView(agree, ' P4) || return 1
  lui=$(one "$b" 'll.addView(ack, ' P4) || return 1
  [ "$lbody" -lt "$lag" ] && [ "$lag" -lt "$lui" ] || {
    echo "  PIN P4 order: body at $lbody, agree added at $lag, ack added at $lui" >&2; return 1; }

  # P5 the one button: enabled only through canContinue(agree, ack), re-checked on every toggle of either box and
  # once at build; the click re-checks, writes the marker, then goes on.
  lg=$(one "$b" 'final Runnable gate = () -> {' P5) || return 1
  lok=$(one "$b" 'boolean ok = OsAgreement.canContinue(agree.isChecked(), ack.isChecked());' P5) || return 1
  len=$(one "$b" 'accept.setEnabled(' P5) || return 1
  lend=$(printf '%s\n' "$b" | awk -v g="$lg" 'NR > g && /^[[:space:]]*};[[:space:]]*$/ { print NR; exit }')
  [ -n "$lend" ] && [ "$lok" -gt "$lg" ] && [ "$len" -gt "$lok" ] && [ "$len" -lt "$lend" ] || {
    echo "  PIN P5 gate at $lg, canContinue at $lok, setEnabled at $len, gate ends at ${lend:-?}" >&2; return 1; }
  one "$b" 'accept.setEnabled(ok);' P5 >/dev/null || return 1
  one "$b" 'agree.setOnCheckedChangeListener((b, c) -> gate.run());' P5 >/dev/null || return 1
  one "$b" 'ack.setOnCheckedChangeListener((b, c) -> gate.run());' P5 >/dev/null || return 1
  n=$(printf '%s\n' "$b" | grep -cE '^[[:space:]]*gate\.run\(\);[[:space:]]*$' || true)
  [ "$n" = 1 ] || { echo "  PIN P5 $n plain gate.run(); lines, want 1" >&2; return 1; }
  lclick=$(one "$b" 'accept.setOnClickListener(v -> {' P5) || return 1
  lchk=$(one "$b" 'if (!OsAgreement.canContinue(agree.isChecked(), ack.isChecked())) return;' P5) || return 1
  lset=$(one "$b" 'setOsAgreementAccepted();' P5) || return 1
  lnext=$(one "$b" 'next.run();' P5) || return 1
  [ "$lchk" = $((lclick + 1)) ] && [ "$lset" = $((lchk + 1)) ] && [ "$lnext" = $((lset + 1)) ] || {
    echo "  PIN P5 click at $lclick: re-check at $lchk, marker at $lset, next at $lnext -- want each on the next line" >&2
    return 1; }
  one "$b" 'll.addView(accept, ' P5 >/dev/null || return 1

  # P6 no way past it: one click listener, no Skip or Back, no other first-run step.
  read -r n _ <<<"$(line_of "$b" 'setOnClickListener(')"
  [ "$n" = 1 ] || { echo "  PIN P6 $n setOnClickListener( in the screen, want 1" >&2; return 1; }
  for n in Skip skip Back showFirstRunOwner showFirstRunWifi finishFirstRun buildFirstRunWelcome setContentView; do
    none "$b" "$n" P6 || return 1
  done
  read -r n _ <<<"$(line_of "$src" 'setOsAgreementAccepted();')"
  [ "$n" = 1 ] || { echo "  PIN P6 $n calls of setOsAgreementAccepted(); in $f, want 1" >&2; return 1; }

  # P7 the marker: the accepted VERSION and its time in the gate's prefs; the read compares with VERSION.
  b=$(body "$f" 'private void setOsAgreementAccepted() {')
  [ -n "$b" ] || { echo "  PIN P7 no setOsAgreementAccepted() in $f" >&2; return 1; }
  for n in 'getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit()' \
           '.putString("os_agreement_accepted", OsAgreement.VERSION)' \
           '.putLong("os_agreement_accepted_at", System.currentTimeMillis()).apply();'; do
    one "$b" "$n" P7 >/dev/null || return 1
  done
  b=$(body "$f" 'private boolean osAgreementAccepted() {')
  [ -n "$b" ] || { echo "  PIN P7 no osAgreementAccepted() in $f" >&2; return 1; }
  one "$b" 'return OsAgreement.VERSION.equals(getSharedPreferences("nowhere_gate", MODE_PRIVATE)' P7 >/dev/null || return 1
  one "$b" '.getString("os_agreement_accepted", null));' P7 >/dev/null || return 1
  echo "  pins ok"
  return 0
}

echo "== $ACT"
suite "$ACT" "$CLS" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/OsAgreement.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 PRODUCTION_APPROVED is true' cls 's/PRODUCTION_APPROVED = false;/PRODUCTION_APPROVED = true;/'
mut 'M2 shouldShow ignores the reply' cls 's/return PRODUCTION_APPROVED \|\| \(daemonReply != null && "draft"\.equals\(daemonReply\.trim\(\)\)\);/return true;/'
mut 'M3 canContinue drops the acknowledgement' cls 's/return accepted && acknowledged;/return accepted;/'
mut 'M4 the acknowledgement merged into the agreement checkbox' act 's/final android\.widget\.CheckBox ack = new android\.widget\.CheckBox\(this\);/final android.widget.CheckBox ack = agree;/; s/agree\.setText\(OsAgreement\.AGREE\);/agree.setText(OsAgreement.AGREE + " " + OsAgreement.ACK);/; s/\n[ \t]*ack\.setText\(OsAgreement\.ACK\);//; s/\n[ \t]*ll\.addView\(ack, kLp\);//'
mut 'M5 the DRAFT mark not added' act 's/\n[ \t]*ll\.addView\(mark, mLp\);//'
mut 'M6 BODY gains "End User License"' cls 's/(static final String BODY_FROM =\n[ \t]*"These terms)/$1 (the End User License)/'
mut 'M7 launchFirstRun(true) goes straight to the welcome' act 's/setContentView\(buildOsAgreementScreen\(\(\) -> setContentView\(buildFirstRunWelcome\(\)\)\)\);/setContentView(buildFirstRunWelcome());/'
mut 'M8 shouldShow takes "draft" as a prefix' cls 's/"draft"\.equals\(daemonReply\.trim\(\)\)/daemonReply.trim().startsWith("draft")/'
mut 'M9 shouldShow does not trim the reply' cls 's/"draft"\.equals\(daemonReply\.trim\(\)\)/"draft".equals(daemonReply)/'
mut 'M10 the first-run thread passes true' act 's/final boolean agreement = OsAgreement\.shouldShow\(sendDaemon\("GET-OS-AGREEMENT\\n"\)\) && !osAgreementAccepted\(\);/final boolean agreement = true;/'
mut 'M11 the button always enabled' act 's/accept\.setEnabled\(ok\);/accept.setEnabled(true);/'
mut 'M12 ACK does not name Nowhere' cls 's/ Not Nowhere, and not anyone else\./ Not anyone else./'
mut 'M13 accept does not write the marker' act 's/\n[ \t]*setOsAgreementAccepted\(\);//'
mut 'M14 a Skip control goes past the screen' act 's/(\n([ \t]*)ll\.addView\(accept, new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);)/$1\n$2TextView skip = new TextView(this);\n$2skip.setText("Skip");\n$2skip.setOnClickListener(v -> next.run());\n$2ll.addView(skip);/'
mut 'M15 BODY says nothing of yours stays on the phone' cls 's/Your profiles are not kept on this phone\./Nothing of yours stays on this phone./'
mut 'M16 the DRAFT mark only with the gate on' act 's/if \(OsAgreement\.showsDraftMark\(\)\) \{/if (!OsAgreement.showsDraftMark()) {/'
mut 'M17 the thread ignores the accepted marker' act 's/ && !osAgreementAccepted\(\);/;/'
mut 'M18 ticking the acknowledgement does not re-check' act 's/ack\.setOnCheckedChangeListener\(\(b, c\) -> gate\.run\(\)\);/ack.setOnCheckedChangeListener((b, c) -> { });/'
mut 'M19 the click does not re-check' act 's/\n[ \t]*if \(!OsAgreement\.canContinue\(agree\.isChecked\(\), ack\.isChecked\(\)\)\) return;//'
mut 'M20 the marker records no time' act 's/\n[ \t]*\.putLong\("os_agreement_accepted_at", System\.currentTimeMillis\(\)\)\.apply\(\);/.apply();/'
mut 'M21 the gate enables on the agreement alone' act 's/boolean ok = OsAgreement\.canContinue\(agree\.isChecked\(\), ack\.isChecked\(\)\);/boolean ok = agree.isChecked();/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
