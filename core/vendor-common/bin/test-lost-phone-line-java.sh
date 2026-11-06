#!/usr/bin/env bash
# test-lost-phone-line-java.sh [--mutate] -- the Change passphrase screen says a lost phone is answered there, under
# javac (NWP-20261111-14, NWP-20261114-22).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (Q011, 2026-10-20 and 2026-10-21) answers a lost phone with a
# passphrase change and puts one line saying so on the Change passphrase screen, under its title; #45 (2026-10-22,
# NWP-20261114-22) decides its words: one text on a profile tied to the phone's chip, a shorter one otherwise. They are
# LostPhoneCopy.TIED and NOT_TIED, picked by LostPhoneCopy.line(<SE-STATUS reply>), pure java, compiled as-is with
# LostPhoneLineCases. The suite reads the two decided texts out of the #45 bullet in docs/product-decisions.md and the
# cases check both byte for byte against them, line() over every SE-STATUS reply, TIED naming the 12 words and NOT_TIED
# never, and neither naming recovery, erase or wipe. The PINS below check the wiring the cases cannot see:
# showChangePass gives one view line(null) (NOT_TIED, true of every shape) and adds it once, after the `sub` line and
# before the `warn` line; then reads SE-STATUS off the UI thread with a short bound and sets that view to line(reply)
# on the UI thread, only while the screen is still showing.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-lost-phone-line-java.sh            # the cases and the pins
#   bash test-lost-phone-line-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/LostPhoneCopy.java"
CASES="$root/core/chooser/tests/lost-phone-line/LostPhoneLineCases.java"
DEC="$root/docs/product-decisions.md"
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

# The decided texts (#45, 2026-10-22): the first two "..." strings of the one #45 bullet, tied then not tied.
[ -f "$DEC" ] || { echo "FAIL: missing $DEC" >&2; exit 2; }
dec_line=$(grep -F -- '- **#45 (dn-1107 #2, Q011)' "$DEC" || true)
dec_n=$(printf '%s' "$dec_line" | grep -c '' || true)
[ "$dec_n" = 1 ] || { echo "FAIL: $dec_n #45 (dn-1107 #2, Q011) bullets in $DEC, want 1" >&2; exit 2; }
DEC_TIED=$(printf '%s\n' "$dec_line" | perl -ne '@q = /"([^"]*)"/g; print $q[0] if @q >= 2')
DEC_NOT=$(printf '%s\n' "$dec_line" | perl -ne '@q = /"([^"]*)"/g; print $q[1] if @q >= 2')
[ -n "$DEC_TIED" ] && [ -n "$DEC_NOT" ] || { echo "FAIL: no two quoted texts in the #45 bullet of $DEC" >&2; exit 2; }

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

# suite <ProfileActivity.java> <LostPhoneCopy.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" b o v nset nadd lsub lv lwarn csub cwarn nse rt st cap lrt lth lui lguard lset nline nst
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/$(basename "$cls")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.LostPhoneLineCases "$DEC_TIED" "$DEC_NOT" || return 1

  b=$(body "$f" 'private void showChangePass(final String name)')
  [ -n "$b" ] || { echo "  PIN P0 no showChangePass in $f" >&2; return 1; }
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//')
  # P1: exactly one view is given line(null) when it is built (NOT_TIED, true of every shape); v is that view. The
  # body never names a text directly: the view always goes through line().
  nset=$(printf '%s\n' "$b" | grep -c 'setText(LostPhoneCopy\.line(null))' || true)
  [ "$nset" = 1 ] || { echo "  PIN P1 $nset setText(LostPhoneCopy.line(null)) in showChangePass, want 1" >&2; return 1; }
  v=$(printf '%s\n' "$b" | perl -ne 'print "$1\n" if /([A-Za-z_]\w*)\.setText\(LostPhoneCopy\.line\(null\)\)/')
  nst=$(printf '%s\n' "$b" | grep -cE 'LostPhoneCopy\.(LINE|TIED|NOT_TIED)' || true)
  [ "$nst" = 0 ] || { echo "  PIN P1 $nst LostPhoneCopy.LINE/TIED/NOT_TIED in showChangePass, want 0" >&2; return 1; }
  # P2: that view is added exactly once
  nadd=$(printf '%s\n' "$b" | grep -cE "ll\\.addView\\($v[,)]" || true)
  [ "$nadd" = 1 ] || { echo "  PIN P2 $nadd ll.addView($v in showChangePass, want 1" >&2; return 1; }
  # P3: it is added after `sub` and before `warn`, each of those added exactly once
  read -r csub lsub <<<"$(line_of "$b" 'll.addView(sub,')"
  read -r cwarn lwarn <<<"$(line_of "$b" 'll.addView(warn,')"
  lv=$(printf '%s\n' "$b" | grep -nE "ll\\.addView\\($v[,)]" | cut -d: -f1)
  [ "$csub" = 1 ] && [ "$cwarn" = 1 ] || {
    echo "  PIN P3 ll.addView(sub, x$csub and ll.addView(warn, x$cwarn in showChangePass, want 1 each" >&2; return 1; }
  [ "$lsub" -lt "$lv" ] && [ "$lv" -lt "$lwarn" ] || {
    echo "  PIN P3 order: sub at $lsub, $v at $lv, warn at $lwarn -- want sub < $v < warn" >&2; return 1; }
  # P4: SE-STATUS is read exactly once, with DaemonSocket.roundTrip and a bound of at most 20 s, never with sendDaemon
  # (its 90 s read); st is the variable the reply goes to.
  nse=$(printf '%s\n' "$b" | grep -c 'SE-STATUS' || true)
  [ "$nse" = 1 ] || { echo "  PIN P4 $nse SE-STATUS in showChangePass, want 1" >&2; return 1; }
  rt=$(printf '%s\n' "$b" | perl -ne 'print "$1 $2\n" if /\b([A-Za-z_]\w*) = DaemonSocket\.roundTrip\("SE-STATUS\\n", (\d+)\)/')
  [ -n "$rt" ] || { echo "  PIN P4 SE-STATUS is not read as <var> = DaemonSocket.roundTrip(\"SE-STATUS\\n\", <ms>)" >&2; return 1; }
  read -r st cap <<<"$rt"
  [ "$cap" -le 20000 ] || { echo "  PIN P4 the SE-STATUS read is bounded at $cap ms, want <= 20000" >&2; return 1; }
  # P5: v is set to line(st) exactly once, on the UI thread, behind the still-showing guard; the read runs in a new
  # Thread. Order: new Thread( (at most 2 lines above) < the read < runOnUiThread( < the guard < the setText.
  read -r nline _ <<<"$(line_of "$b" 'setText(LostPhoneCopy.line(')"
  [ "$nline" = 2 ] || { echo "  PIN P5 $nline setText(LostPhoneCopy.line( in showChangePass, want 2" >&2; return 1; }
  read -r nset lset <<<"$(line_of "$b" "$v.setText(LostPhoneCopy.line($st));")"
  [ "$nset" = 1 ] || { echo "  PIN P5 $nset $v.setText(LostPhoneCopy.line($st)); in showChangePass, want 1" >&2; return 1; }
  lrt=$(printf '%s\n' "$b" | grep -n 'DaemonSocket\.roundTrip("SE-STATUS' | cut -d: -f1)
  lth=$(printf '%s\n' "$b" | awk -v r="$lrt" 'NR < r && NR >= r - 2 && index($0, "new Thread(") { l=NR } END { print l+0 }')
  lui=$(printf '%s\n' "$b" | awk -v r="$lrt" -v e="$lset" 'NR > r && NR < e && index($0, "runOnUiThread(") { l=NR } END { print l+0 }')
  lguard=$(printf '%s\n' "$b" | awk -v r="$lui" -v e="$lset" 'NR > r && NR < e && index($0, "!ll.isAttachedToWindow()") && index($0, "return") { l=NR } END { print l+0 }')
  [ "$lth" -gt 0 ] || { echo "  PIN P5 no new Thread( just above the SE-STATUS read at $lrt" >&2; return 1; }
  [ "$lui" -gt 0 ] || { echo "  PIN P5 no runOnUiThread( between the read at $lrt and the setText at $lset" >&2; return 1; }
  [ "$lguard" -gt 0 ] || {
    echo "  PIN P5 no !ll.isAttachedToWindow() return between runOnUiThread( at $lui and the setText at $lset" >&2; return 1; }
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
  d=$(mktemp -d -p "$W"); a="$d/ProfileActivity.java"; c="$d/LostPhoneCopy.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 the addView removed' act 's/\n[ \t]*ll\.addView\(lost, llp\);//'
mut 'M2 the line added after warn' act 's/\n([ \t]*)ll\.addView\(lost, llp\);//; s/(\n([ \t]*)ll\.addView\(warn, wlp\);)/$1\n$2ll.addView(lost, llp);/'
mut 'M3 NOT_TIED gains the 12-words clause' cls 's/("anywhere\.)"/$1 You\x27ll add each phone you keep again with your 12 words."/'
mut 'M4 the line added twice' act 's/(\n([ \t]*)ll\.addView\(lost, llp\);)/$1\n$2ll.addView(lost, llp);/'
mut 'M5 TIED says it erases the lost phone' cls 's/(12 words\.)"/$1 It erases the lost phone."/'
mut 'M6 line maps OK TIED PARTIAL to NOT_TIED' cls 's/ \|\| "OK TIED PARTIAL"\.equals\(s\)//'
mut 'M7 line returns TIED on null' cls 's/(static String line\(String seStatus\) \{\n)/$1        if (seStatus == null) return TIED;\n/'
mut 'M8 showChangePass never reads SE-STATUS' act 's/DaemonSocket\.roundTrip\("SE-STATUS\\n", 15000\)/""/'
mut 'M9 the initial text is TIED' act 's/lost\.setText\(LostPhoneCopy\.line\(null\)\)/lost.setText(LostPhoneCopy.TIED)/'
mut 'M10 the old LINE restored in the class' cls 's/(private LostPhoneCopy\(\) \{\}\n)/$1\n    static final String LINE =\n            "Lost a phone? Change your passphrase here: the lost phone can no longer sign in to this profile.";\n/'
mut 'M11 the old LINE wiring restored' act 's/lost\.setText\(LostPhoneCopy\.line\(null\)\)/lost.setText(LostPhoneCopy.LINE)/'
mut 'M12 the still-showing guard removed' act 's/\n[^\n]*isAttachedToWindow\(\)\) return; \/\/ the user left this screen//'
mut 'M13 SE-STATUS read with sendDaemon (90 s)' act 's/DaemonSocket\.roundTrip\("SE-STATUS\\n", 15000\)/sendDaemon("SE-STATUS\\n")/'
mut 'M14 line does not trim the reply' cls 's/seStatus\.trim\(\)/seStatus/'
mut 'M15 the reply never reaches the view' act 's/\n[ \t]*lost\.setText\(LostPhoneCopy\.line\(st\)\);//'
mut 'M16 line matches OK TIED as a prefix' cls 's/"OK TIED"\.equals\(s\)/s.startsWith("OK TIED")/'
mut 'M17 the read bounded at 90 s' act 's/(roundTrip\("SE-STATUS\\n", )15000\)/${1}90000)/'
mut 'M18 the read on the UI thread' act 's/new Thread\(\(\) -> \{\n([ \t]*final String st = DaemonSocket\.roundTrip\("SE-STATUS)/{\n$1/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
