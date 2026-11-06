#!/usr/bin/env bash
# test-change-pass-hint-java.sh [--mutate] -- the Change passphrase screen shows a live strength hint for the new
# passphrase, under javac (NWP-20261116-25).
#
# WHY THIS IS COMMITTED. docs/credential-tiers.md tier 1a mirrors the passphrase floor in the chooser UI so that a
# refusal is never the first feedback. Since NWP-20261115-04, ROTATE answers `WEAK <reason>` before it reads the
# session, so without a hint a below-floor new passphrase was first reported after Change was tapped. StrengthHint
# (pure java) turns a CHECK-PASSPHRASE reply into the hint line with ReplyCopy.strength's words; it is compiled as-is
# with the real ReplyCopy and StrengthHintCases. The PINS below check the wiring the cases cannot see: showChangePass
# debounces newP's text by 350 ms, sends nothing for an empty text, reads CHECK-PASSPHRASE off the UI thread with the
# screen's own name and a short bound, and shows the reply only while the screen is still showing and the text is
# the one that was checked. The hint sits between the new and the confirm field. Nothing logs the passphrase.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-change-pass-hint-java.sh            # the cases and the pins
#   bash test-change-pass-hint-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ProfileActivity.java"
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

# first_between <text> <from> <to> <fixed-string> -> the first line number in (from, to) holding the string, else 0
first_between() {
  printf '%s\n' "$1" | awk -v f="$2" -v t="$3" -v s="$4" \
    'NR > f && NR < t && index($0, s) && !l { l=NR } END { print l+0 }'
}

# suite <ProfileActivity.java> <StrengthHint.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" b o rt v cap n lrt lpw lth lempty lui lguard lstale lset lcol lvis nl ll lrm lpd
  local lnew lconf lhint nnew nconf
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

  b=$(body "$f" 'private void showChangePass(final String name)')
  [ -n "$b" ] || { echo "  PIN H0 no showChangePass in $f" >&2; return 1; }
  # Comments never satisfy a pin: whole-line comments are dropped, and a trailing // comment with no quote after it.
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//' | perl -pe 's{\s+//[^"\n]*$}{}')
  # H1: exactly one CHECK-PASSPHRASE
  read -r n _ <<<"$(line_of "$b" 'CHECK-PASSPHRASE')"
  [ "$n" = 1 ] || { echo "  PIN H1 $n CHECK-PASSPHRASE in showChangePass, want 1" >&2; return 1; }
  # H2: it is DaemonSocket.roundTrip with the screen's own name and a bound of at most 15 s; v is the text sent
  rt=$(printf '%s\n' "$b" | perl -ne 'print "$1 $2\n" if /= DaemonSocket\.roundTrip\("CHECK-PASSPHRASE\\n" \+ name \+ "\\n" \+ ([A-Za-z_]\w*) \+ "\\n", (\d+)\)/')
  [ -n "$rt" ] || {
    echo "  PIN H2 CHECK-PASSPHRASE is not sent as DaemonSocket.roundTrip(\"CHECK-PASSPHRASE\\n\" + name + \"\\n\" + <v> + \"\\n\", <ms>)" >&2
    return 1; }
  read -r v cap <<<"$rt"
  [ "$cap" -le 15000 ] || { echo "  PIN H2 the CHECK-PASSPHRASE read is bounded at $cap ms, want <= 15000" >&2; return 1; }
  lrt=$(printf '%s\n' "$b" | grep -n 'CHECK-PASSPHRASE' | cut -d: -f1)
  # H3: v is read from newP, above the send
  read -r n lpw <<<"$(line_of "$b" "final String $v = newP.getText().toString();")"
  [ "$n" = 1 ] || { echo "  PIN H3 $n 'final String $v = newP.getText().toString();' in showChangePass, want 1" >&2; return 1; }
  [ "$lpw" -lt "$lrt" ] || { echo "  PIN H3 $v is read at $lpw, after the send at $lrt" >&2; return 1; }
  # H4: the send runs in a new Thread opened at most 2 lines above it, after the read of v
  lth=$(printf '%s\n' "$b" | awk -v r="$lrt" 'NR < r && NR >= r - 2 && index($0, "new Thread(") { l=NR } END { print l+0 }')
  [ "$lth" -gt "$lpw" ] || { echo "  PIN H4 no new Thread( just above the send at $lrt (after the read at $lpw)" >&2; return 1; }
  # H5: an empty text hides the hint and returns before the Thread, so nothing is sent
  lempty=$(printf '%s\n' "$b" | awk -v f="$lpw" -v t="$lth" -v v="$v" 'NR > f && NR < t &&
    index($0, "if (" v ".isEmpty()) {") && index($0, "hint.setVisibility(android.view.View.GONE); return;") { l=NR } END { print l+0 }')
  [ "$lempty" -gt 0 ] || {
    echo "  PIN H5 no 'if ($v.isEmpty()) { hint.setVisibility(android.view.View.GONE); return;' between $lpw and $lth" >&2; return 1; }
  # H6: exactly one text listener, on newP
  read -r n _ <<<"$(line_of "$b" 'addTextChangedListener')"
  read -r nl ll <<<"$(line_of "$b" 'newP.addTextChangedListener(')"
  [ "$n" = 1 ] && [ "$nl" = 1 ] || {
    echo "  PIN H6 $n addTextChangedListener and $nl newP.addTextChangedListener( in showChangePass, want 1 each" >&2; return 1; }
  # H7: after it, removeCallbacks(check) once, then postDelayed(check, 350) once
  read -r n lrm <<<"$(line_of "$b" 'removeCallbacks(check)')"
  [ "$n" = 1 ] || { echo "  PIN H7 $n removeCallbacks(check) in showChangePass, want 1" >&2; return 1; }
  read -r n lpd <<<"$(line_of "$b" 'postDelayed(check, 350)')"
  [ "$n" = 1 ] || { echo "  PIN H7 $n postDelayed(check, 350) in showChangePass, want 1" >&2; return 1; }
  [ "$ll" -lt "$lrm" ] && [ "$lrm" -lt "$lpd" ] || {
    echo "  PIN H7 order: listener at $ll, removeCallbacks at $lrm, postDelayed at $lpd -- want listener < remove < post" >&2
    return 1; }
  # H8: the reply is shown on the UI thread, behind the still-showing guard and the same-text guard
  read -r n lset <<<"$(line_of "$b" 'hint.setText(StrengthHint.line(')"
  [ "$n" = 1 ] || { echo "  PIN H8 $n hint.setText(StrengthHint.line( in showChangePass, want 1" >&2; return 1; }
  lui=$(first_between "$b" "$lrt" "$lset" 'runOnUiThread(')
  [ "$lui" -gt 0 ] || { echo "  PIN H8 no runOnUiThread( between the send at $lrt and the setText at $lset" >&2; return 1; }
  lguard=$(printf '%s\n' "$b" | awk -v f="$lui" -v t="$lset" 'NR > f && NR < t &&
    index($0, "isFinishing() || isDestroyed() || !ll.isAttachedToWindow()") && index($0, "return") { l=NR } END { print l+0 }')
  [ "$lguard" -gt 0 ] || { echo "  PIN H8 no still-showing guard with return between $lui and the setText at $lset" >&2; return 1; }
  lstale=$(printf '%s\n' "$b" | awk -v f="$lui" -v t="$lset" -v v="$v" 'NR > f && NR < t &&
    index($0, v ".equals(newP.getText()") && index($0, "return") { l=NR } END { print l+0 }')
  [ "$lstale" -gt 0 ] || { echo "  PIN H8 no '$v.equals(newP.getText()' guard with return between $lui and the setText at $lset" >&2; return 1; }
  # H9: the colour follows StrengthHint.strong, and the hint is made visible after its text is set
  read -r n lcol <<<"$(line_of "$b" 'hint.setTextColor(StrengthHint.strong(')"
  [ "$n" = 1 ] || { echo "  PIN H9 $n hint.setTextColor(StrengthHint.strong( in showChangePass, want 1" >&2; return 1; }
  lvis=$(printf '%s\n' "$b" | awk -v f="$lset" 'NR > f && index($0, "hint.setVisibility(android.view.View.VISIBLE)") && !l { l=NR } END { print l+0 }')
  [ "$lvis" -gt 0 ] || { echo "  PIN H9 no hint.setVisibility(android.view.View.VISIBLE) after the setText at $lset" >&2; return 1; }
  # H10: the hint is added once, between the new field and the confirm field
  read -r n lhint <<<"$(line_of "$b" 'll.addView(hint,')"
  read -r nnew lnew <<<"$(line_of "$b" 'll.addView(PassReveal.wrap(newP,')"
  read -r nconf lconf <<<"$(line_of "$b" 'll.addView(PassReveal.wrap(confP,')"
  [ "$n" = 1 ] && [ "$nnew" = 1 ] && [ "$nconf" = 1 ] || {
    echo "  PIN H10 ll.addView(hint, x$n, newP's addView x$nnew, confP's addView x$nconf, want 1 each" >&2; return 1; }
  [ "$lnew" -lt "$lhint" ] && [ "$lhint" -lt "$lconf" ] || {
    echo "  PIN H10 order: newP at $lnew, hint at $lhint, confP at $lconf -- want newP < hint < confP" >&2; return 1; }
  # H11: the hint is 12 sp and starts GONE, before it is added
  read -r n _ <<<"$(line_of "$b" 'hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);')"
  [ "$n" = 1 ] || { echo "  PIN H11 $n hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12); in showChangePass, want 1" >&2; return 1; }
  [ "$(first_between "$b" 0 "$lhint" 'hint.setVisibility(android.view.View.GONE);')" -gt 0 ] || {
    echo "  PIN H11 the hint is not set GONE before it is added at $lhint" >&2; return 1; }
  # H12: no Log. line names the passphrase variable
  n=$(printf '%s\n' "$b" | perl -ne "\$n++ if /\\bLog\\./ && /\\b\Q$v\E\\b/; END { print \$n+0 }")
  [ "$n" = 0 ] || { echo "  PIN H12 $n Log. line(s) in showChangePass name $v, want 0" >&2; return 1; }
  # H13: the Change button still sends ROTATE with the screen's name: the hint is not the authority
  n=$(printf '%s\n' "$b" | grep -cF 'sendDaemon("ROTATE\n" + name + ' || true)
  [ "$n" = 1 ] || { echo "  PIN H13 $n sendDaemon(\"ROTATE\\n\" + name + in showChangePass, want 1" >&2; return 1; }
  echo "  pins ok"
  return 0
}

# CHP_PA / CHP_CLS point the plain run at other copies (to show the pins fail on an older ProfileActivity); the
# mutants always start from the tree's own files.
echo "== ${CHP_PA:-$ACT}"
suite "${CHP_PA:-$ACT}" "${CHP_CLS:-$CLS}" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>. showSaveCeremony holds the same debounce lines earlier in the file, so a
# mutant of a line both methods share is anchored after `private void showChangePass(` (perl /s, non-greedy).
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ProfileActivity.java"; c="$d/StrengthHint.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 the listener on oldP' act 's/newP\.addTextChangedListener\(/oldP.addTextChangedListener(/'
mut 'M2 the check reads oldP' act 's/final String pw = newP\.getText\(\)\.toString\(\);/final String pw = oldP.getText().toString();/'
mut 'M3 profileName() for name' act 's/("CHECK-PASSPHRASE\\n" \+ )name( \+)/${1}profileName()$2/'
mut 'M4 removeCallbacks dropped' act 's/(private void showChangePass\(.*?)\n[ \t]*h\.removeCallbacks\(check\);/$1/s'
mut 'M5 the empty guard dropped' act 's/(private void showChangePass\(.*?)\n[ \t]*if \(pw\.isEmpty\(\)\) \{ hint\.setVisibility\(android\.view\.View\.GONE\); return; \}/$1/s'
mut 'M6 the stale-text check dropped' act 's/\n[ \t]*if \(!pw\.equals\(newP\.getText\(\)\.toString\(\)\)\) return;[^\n]*//'
mut 'M7 the two prefixes swapped' cls 's/return "✓ "/return "\@\@"/; s/return "• "/return "✓ "/; s/return "\@\@"/return "• "/'
mut 'M8 the hint added after confP' act 's/\n([ \t]*)ll\.addView\(hint, fieldLp\(dp\(11\)\)\);//; s/(\n([ \t]*)ll\.addView\(PassReveal\.wrap\(confP, [^\n]*)/$1\n$2ll.addView(hint, fieldLp(dp(11)));/'
mut 'M9 the still-showing guard dropped' act 's/\n[^\n]*isAttachedToWindow\(\)\) return; \/\/ the screen is gone//'
mut 'M10 the check sent with sendDaemon (90 s)' act 's/DaemonSocket\.roundTrip\(("CHECK-PASSPHRASE\\n" \+ name \+ "\\n" \+ pw \+ "\\n"), 10000\)/sendDaemon($1)/'
mut 'M11 the check bounded at 90 s' act 's/(\+ pw \+ "\\n", )10000\)/${1}90000)/'
mut 'M12 the check on the UI thread' act 's/new Thread\(\(\) -> \{\n([ \t]*final String r = DaemonSocket\.roundTrip\("CHECK-PASSPHRASE)/{\n$1/'
mut 'M13 strong is true for WEAK' cls 's/(static boolean strong\(String reply\) \{\n[^\n]*State\.)STRONG/${1}WEAK/'
mut 'M14 no debounce' act 's/(private void showChangePass\(.*?)h\.postDelayed\(check, 350\)/$1h.post(check)/s'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
