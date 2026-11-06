#!/usr/bin/env bash
# test-recover-hint-java.sh [--mutate] -- the Reset passphrase screen shows a live strength hint for the new
# passphrase, under javac (NWP-20261117-36).
#
# WHY THIS IS COMMITTED. docs/credential-tiers.md tier 1a mirrors the passphrase floor in the chooser UI so that a
# refusal is never the first feedback. Since NOWHERE-1214, RECOVER answers `WEAK <reason>`, so without a hint a
# below-floor new passphrase was first reported after Reset was tapped. StrengthHint (pure java) turns a
# CHECK-PASSPHRASE reply into the hint line with ReplyCopy.strength's words; it is compiled as-is with the real
# ReplyCopy and StrengthHintCases (read only, from the change-pass-hint suite). The PINS below check the wiring the
# cases cannot see: buildRecoverScreen debounces newP's and nameF's text by 350 ms, sends nothing for an empty
# passphrase, reads CHECK-PASSPHRASE off the UI thread with the trimmed name and a short bound, and shows the reply
# only while the screen is still showing and both texts are the ones that were checked, in showStrength's colours.
# The hint sits between the new passphrase and the Reset button. Nothing logs the passphrase or the name.
# CHECK-PASSPHRASE names no profile (passphraseStrong(name, pass) reads no store), so the hint is blind-safe.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-recover-hint-java.sh            # the cases and the pins
#   bash test-recover-hint-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/StrengthHint.java"
COPY="$SRCDIR/ReplyCopy.java"
CASES="$root/core/chooser/tests/change-pass-hint/StrengthHintCases.java"
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

# line_of <text> <fixed-string> -> "<count> <first line number>" of the lines holding the string
line_of() {
  printf '%s\n' "$1" | awk -v s="$2" 'index($0, s) { n++; if (!first) first=NR } END { print n+0, first+0 }'
}

# nth_of <text> <fixed-string> <n> -> the line number of the n-th line holding the string, else 0
nth_of() {
  printf '%s\n' "$1" | awk -v s="$2" -v k="$3" 'index($0, s) { n++; if (n == k) l=NR } END { print l+0 }'
}

# first_between <text> <from> <to> <fixed-string> -> the first line number in (from, to) holding the string, else 0
first_between() {
  printf '%s\n' "$1" | awk -v f="$2" -v t="$3" -v s="$4" \
    'NR > f && NR < t && index($0, s) && !l { l=NR } END { print l+0 }'
}

# count_between <text> <from> <to> <fixed-string> -> how many lines in (from, to) hold the string
count_between() {
  printf '%s\n' "$1" | awk -v f="$2" -v t="$3" -v s="$4" \
    'NR > f && NR < t && index($0, s) { n++ } END { print n+0 }'
}

# suite <ChooserActivity.java> <StrengthHint.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" b o rt nmv v cap n lck lend lrt lpw lnm lth lempty lui lguard lstale lset lcol lvis
  local nn nl1 nl2 lrm1 lrm2 lpd1 lpd2 lhint lnew lreset nnew nreset
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$COPY" ] || { echo "  FAIL missing $COPY" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$COPY" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" \
    "$o/$(basename "$cls")" "$o/$(basename "$COPY")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$o" com.nowhere.chooser.StrengthHintCases || return 1

  b=$(body "$f" 'private View buildRecoverScreen()')
  [ -n "$b" ] || { echo "  PIN R0 no buildRecoverScreen in $f" >&2; return 1; }
  # Comments never satisfy a pin: whole-line comments are dropped, and a trailing // comment with no quote after it.
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//' | perl -pe 's{\s+//[^"\n]*$}{}')
  # R1: exactly one CHECK-PASSPHRASE
  read -r n _ <<<"$(line_of "$b" 'CHECK-PASSPHRASE')"
  [ "$n" = 1 ] || { echo "  PIN R1 $n CHECK-PASSPHRASE in buildRecoverScreen, want 1" >&2; return 1; }
  # R2: it is DaemonSocket.roundTrip(name, pass) with a bound of at most 15 s; nmv is the name sent, v the text sent
  rt=$(printf '%s\n' "$b" | perl -ne 'print "$1 $2 $3\n" if /= DaemonSocket\.roundTrip\("CHECK-PASSPHRASE\\n" \+ ([A-Za-z_]\w*) \+ "\\n" \+ ([A-Za-z_]\w*) \+ "\\n", (\d+)\)/')
  [ -n "$rt" ] || {
    echo "  PIN R2 CHECK-PASSPHRASE is not sent as DaemonSocket.roundTrip(\"CHECK-PASSPHRASE\\n\" + <name> + \"\\n\" + <v> + \"\\n\", <ms>)" >&2
    return 1; }
  read -r nmv v cap <<<"$rt"
  [ "$cap" -le 15000 ] || { echo "  PIN R2 the CHECK-PASSPHRASE read is bounded at $cap ms, want <= 15000" >&2; return 1; }
  lrt=$(printf '%s\n' "$b" | grep -n 'CHECK-PASSPHRASE' | cut -d: -f1)
  # The check runnable: from `final Runnable check = () -> {` to the first `};` at its own indent after it. The Reset
  # lambda reads nameF the same way, so the reads below are looked for inside the runnable only.
  read -r n lck <<<"$(line_of "$b" 'final Runnable check = () -> {')"
  [ "$n" = 1 ] || { echo "  PIN R3 $n 'final Runnable check = () -> {' in buildRecoverScreen, want 1" >&2; return 1; }
  lend=$(printf '%s\n' "$b" | awk -v f="$lck" 'NR > f && /^        };[[:space:]]*$/ && !l { l=NR } END { print l+0 }')
  [ "$lend" -gt "$lrt" ] || { echo "  PIN R3 the check runnable (from $lck) does not close after the send at $lrt" >&2; return 1; }
  # R3: v is read from newP inside the runnable, above the send
  n=$(count_between "$b" "$lck" "$lrt" "final String $v = newP.getText().toString();")
  lpw=$(first_between "$b" "$lck" "$lrt" "final String $v = newP.getText().toString();")
  [ "$n" = 1 ] || { echo "  PIN R3 $n 'final String $v = newP.getText().toString();' in the check above the send, want 1" >&2; return 1; }
  # R4: the name sent is nameF's text, trimmed, read inside the runnable above the send; the runnable never reads phraseF
  n=$(count_between "$b" "$lck" "$lrt" "final String $nmv = nameF.getText().toString().trim();")
  lnm=$(first_between "$b" "$lck" "$lrt" "final String $nmv = nameF.getText().toString().trim();")
  [ "$n" = 1 ] || { echo "  PIN R4 $n 'final String $nmv = nameF.getText().toString().trim();' in the check above the send, want 1" >&2; return 1; }
  n=$(count_between "$b" "$lck" "$lend" 'phraseF')
  [ "$n" = 0 ] || { echo "  PIN R4 the check runnable names phraseF on $n line(s), want 0" >&2; return 1; }
  # R5: the send runs in a new Thread opened at most 2 lines above it, after both reads
  lth=$(printf '%s\n' "$b" | awk -v r="$lrt" 'NR < r && NR >= r - 2 && index($0, "new Thread(") { l=NR } END { print l+0 }')
  [ "$lth" -gt "$lpw" ] && [ "$lth" -gt "$lnm" ] || {
    echo "  PIN R5 no new Thread( just above the send at $lrt (after the reads at $lpw and $lnm)" >&2; return 1; }
  # R6: an empty passphrase hides the hint and returns before the Thread, so nothing is sent
  lempty=$(printf '%s\n' "$b" | awk -v f="$lpw" -v t="$lth" -v v="$v" 'NR > f && NR < t &&
    index($0, "if (" v ".isEmpty()) {") && index($0, "hint.setVisibility(android.view.View.GONE); return;") { l=NR } END { print l+0 }')
  [ "$lempty" -gt 0 ] || {
    echo "  PIN R6 no 'if ($v.isEmpty()) { hint.setVisibility(android.view.View.GONE); return;' between $lpw and $lth" >&2; return 1; }
  # R7: exactly two text listeners, one on newP and one on nameF
  read -r n _ <<<"$(line_of "$b" 'addTextChangedListener')"
  read -r nn nl1 <<<"$(line_of "$b" 'newP.addTextChangedListener(')"
  [ "$n" = 2 ] && [ "$nn" = 1 ] || {
    echo "  PIN R7 $n addTextChangedListener and $nn newP.addTextChangedListener( in buildRecoverScreen, want 2 and 1" >&2; return 1; }
  read -r nn nl2 <<<"$(line_of "$b" 'nameF.addTextChangedListener(')"
  [ "$nn" = 1 ] || { echo "  PIN R7 $nn nameF.addTextChangedListener( in buildRecoverScreen, want 1" >&2; return 1; }
  # R8: each listener does removeCallbacks(check), then postDelayed(check, 350), before the next listener opens
  read -r n _ <<<"$(line_of "$b" 'removeCallbacks(check)')"
  [ "$n" = 2 ] || { echo "  PIN R8 $n removeCallbacks(check) in buildRecoverScreen, want 2" >&2; return 1; }
  read -r n _ <<<"$(line_of "$b" 'postDelayed(check, 350)')"
  [ "$n" = 2 ] || { echo "  PIN R8 $n postDelayed(check, 350) in buildRecoverScreen, want 2" >&2; return 1; }
  if [ "$nl1" -lt "$nl2" ]; then local la="$nl1" lb="$nl2"; else local la="$nl2" lb="$nl1"; fi
  lrm1=$(nth_of "$b" 'removeCallbacks(check)' 1); lrm2=$(nth_of "$b" 'removeCallbacks(check)' 2)
  lpd1=$(nth_of "$b" 'postDelayed(check, 350)' 1); lpd2=$(nth_of "$b" 'postDelayed(check, 350)' 2)
  [ "$la" -lt "$lrm1" ] && [ "$lrm1" -lt "$lpd1" ] && [ "$lpd1" -lt "$lb" ] && [ "$lb" -lt "$lrm2" ] && [ "$lrm2" -lt "$lpd2" ] || {
    echo "  PIN R8 order: listeners at $la/$lb, removeCallbacks at $lrm1/$lrm2, postDelayed at $lpd1/$lpd2 -- want each listener < remove < post" >&2
    return 1; }
  # R9: the reply is shown on the UI thread, behind the still-showing guard and the same-texts guard
  read -r n lset <<<"$(line_of "$b" 'hint.setText(StrengthHint.line(')"
  [ "$n" = 1 ] || { echo "  PIN R9 $n hint.setText(StrengthHint.line( in buildRecoverScreen, want 1" >&2; return 1; }
  lui=$(first_between "$b" "$lrt" "$lset" 'runOnUiThread(')
  [ "$lui" -gt 0 ] || { echo "  PIN R9 no runOnUiThread( between the send at $lrt and the setText at $lset" >&2; return 1; }
  lguard=$(printf '%s\n' "$b" | awk -v f="$lui" -v t="$lset" 'NR > f && NR < t &&
    index($0, "!ll.isAttachedToWindow()") && index($0, "return") { l=NR } END { print l+0 }')
  [ "$lguard" -gt 0 ] || { echo "  PIN R9 no '!ll.isAttachedToWindow()' guard with return between $lui and the setText at $lset" >&2; return 1; }
  lstale=$(printf '%s\n' "$b" | awk -v f="$lui" -v t="$lset" -v v="$v" -v m="$nmv" 'NR > f && NR < t &&
    index($0, "!" v ".equals(newP.getText().toString())") && index($0, "!" m ".equals(nameF.getText().toString().trim())") &&
    index($0, "return") { l=NR } END { print l+0 }')
  [ "$lstale" -gt 0 ] || {
    echo "  PIN R9 no '$v.equals(newP...)' + '$nmv.equals(nameF...trim())' guard with return between $lui and the setText at $lset" >&2
    return 1; }
  # R10: showStrength's colours (ACCENT strong, FOOTER weak, MUTED no answer) from ReplyCopy.strength(r).state, and
  # the hint is made visible after its text is set
  n=$(count_between "$b" "$lui" "$lset" 'final ReplyCopy.State st = ReplyCopy.strength(r).state;')
  [ "$n" = 1 ] || { echo "  PIN R10 $n 'final ReplyCopy.State st = ReplyCopy.strength(r).state;' before the setText, want 1" >&2; return 1; }
  read -r n lcol <<<"$(line_of "$b" 'hint.setTextColor(')"
  [ "$n" = 1 ] || { echo "  PIN R10 $n hint.setTextColor( in buildRecoverScreen, want 1" >&2; return 1; }
  printf '%s\n' "$b" | sed -n "${lcol}p" | grep -qF 'hint.setTextColor(st == ReplyCopy.State.STRONG ? ACCENT : st == ReplyCopy.State.UNKNOWN ? MUTED : FOOTER);' || {
    echo "  PIN R10 the hint colour is not 'st == STRONG ? ACCENT : st == UNKNOWN ? MUTED : FOOTER'" >&2; return 1; }
  lvis=$(printf '%s\n' "$b" | awk -v f="$lset" 'NR > f && index($0, "hint.setVisibility(android.view.View.VISIBLE)") && !l { l=NR } END { print l+0 }')
  [ "$lvis" -gt 0 ] || { echo "  PIN R10 no hint.setVisibility(android.view.View.VISIBLE) after the setText at $lset" >&2; return 1; }
  # R11: the hint is added once, between the new passphrase field and the Reset button
  read -r n lhint <<<"$(line_of "$b" 'll.addView(hint,')"
  read -r nnew lnew <<<"$(line_of "$b" 'll.addView(PassReveal.wrap(newP,')"
  read -r nreset lreset <<<"$(line_of "$b" 'll.addView(reset,')"
  [ "$n" = 1 ] && [ "$nnew" = 1 ] && [ "$nreset" = 1 ] || {
    echo "  PIN R11 ll.addView(hint, x$n, newP's addView x$nnew, reset's addView x$nreset, want 1 each" >&2; return 1; }
  [ "$lnew" -lt "$lhint" ] && [ "$lhint" -lt "$lreset" ] || {
    echo "  PIN R11 order: newP at $lnew, hint at $lhint, Reset at $lreset -- want newP < hint < Reset" >&2; return 1; }
  # R12: the hint is 12 sp and starts GONE, before it is added
  read -r n _ <<<"$(line_of "$b" 'hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);')"
  [ "$n" = 1 ] || { echo "  PIN R12 $n hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12); in buildRecoverScreen, want 1" >&2; return 1; }
  [ "$(first_between "$b" 0 "$lhint" 'hint.setVisibility(android.view.View.GONE);')" -gt 0 ] || {
    echo "  PIN R12 the hint is not set GONE before it is added at $lhint" >&2; return 1; }
  # R13: no Log. line names the passphrase, the name or a field's text
  n=$(printf '%s\n' "$b" | perl -ne "\$n++ if /\\bLog\\./ && (/\\b\Q$v\E\\b/ || /\\b\Q$nmv\E\\b/ || /getText/); END { print \$n+0 }")
  [ "$n" = 0 ] || { echo "  PIN R13 $n Log. line(s) in buildRecoverScreen name $v, $nmv or a getText, want 0" >&2; return 1; }
  # R14: the Reset button still sends RECOVER: the hint is not the authority
  n=$(printf '%s\n' "$b" | grep -cF 'sendDaemon("RECOVER\n" + nm + "\n" + ph + "\n" + np + "\n")' || true)
  [ "$n" = 1 ] || { echo "  PIN R14 $n sendDaemon(\"RECOVER\\n\" + nm + ... + np + \"\\n\") in buildRecoverScreen, want 1" >&2; return 1; }
  echo "  pins ok"
  return 0
}

# RH_CA / RH_CLS point the plain run at other copies (to show the pins fail on an older ChooserActivity); the mutants
# always start from the tree's own files.
echo "== ${RH_CA:-$ACT}"
suite "${RH_CA:-$ACT}" "${RH_CLS:-$CLS}" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>. ChooserActivity is a large file and some lines of the check also occur
# in other members, so a mutant is anchored after `private View buildRecoverScreen(` (perl /s, non-greedy).
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/StrengthHint.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
A='private View buildRecoverScreen\('
mut 'M1 the listener on phraseF' act "s/($A.*?)newP\\.addTextChangedListener\\(/\${1}phraseF.addTextChangedListener(/s"
mut 'M2 the check reads phraseF' act "s/($A.*?)final String pw = newP\\.getText\\(\\)\\.toString\\(\\);/\${1}final String pw = phraseF.getText().toString();/s"
mut 'M3 the name not sent' act "s/($A.*?\"CHECK-PASSPHRASE\\\\n\" \\+ )nm( \\+)/\${1}\"\"\$2/s"
mut 'M4 removeCallbacks dropped' act "s/($A.*?)\\n[ \\t]*h\\.removeCallbacks\\(check\\);/\$1/s"
mut 'M5 the empty guard dropped' act "s/($A.*?)\\n[ \\t]*if \\(pw\\.isEmpty\\(\\)\\) \\{ hint\\.setVisibility\\(android\\.view\\.View\\.GONE\\); return; \\}/\$1/s"
mut 'M6 the stale-text check dropped' act "s/($A.*?)\\n[ \\t]*if \\(!pw\\.equals\\(newP\\.getText\\(\\)\\.toString\\(\\)\\)[^\\n]*/\$1/s"
mut 'M7 the hint added after the Reset button' act "s/($A.*?)\\n[ \\t]*ll\\.addView\\(hint, fieldLp\\(dp\\(11\\)\\)\\);(.*?\\n([ \\t]*)ll\\.addView\\(reset, [^\\n]*)/\$1\$2\\n\$3ll.addView(hint, fieldLp(dp(11)));/s"
mut 'M8 the call on the UI thread' act "s/($A.*?)new Thread\\(\\(\\) -> \\{\\n([ \\t]*final String r = DaemonSocket\\.roundTrip\\(\"CHECK-PASSPHRASE)/\$1\\{\\n\$2/s"
mut 'M9 the still-showing guard dropped' act "s/($A.*?)\\n[^\\n]*isAttachedToWindow\\(\\)\\) return;[^\\n]*/\$1/s"
mut 'M10 the check bounded at 90 s' act "s/(\\+ pw \\+ \"\\\\n\", )10000\\)/\${1}90000)/"
mut 'M11 the name read untrimmed' act "s/(final Runnable check = .*?final String nm = nameF\\.getText\\(\\)\\.toString\\(\\))\\.trim\\(\\)/\$1/s"
mut 'M12 the name stale check dropped' act "s/($A.*?) \\|\\| !nm\\.equals\\(nameF\\.getText\\(\\)\\.toString\\(\\)\\.trim\\(\\)\\)\\) return;/\$1) return;/s"
mut 'M13 weak shown in the strong colour' act "s/($A.*?)UNKNOWN \\? MUTED : FOOTER\\);/\${1}UNKNOWN ? MUTED : ACCENT);/s"
mut 'M14 no debounce on the name' act "s/(nameF\\.addTextChangedListener\\(.*?)h\\.postDelayed\\(check, 350\\)/\$1h.post(check)/s"
mut 'M15 the two prefixes swapped' cls 's/return "✓ "/return "\@\@"/; s/return "• "/return "✓ "/; s/return "\@\@"/return "• "/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
