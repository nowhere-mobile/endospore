#!/usr/bin/env bash
# test-device-name-java.sh [--mutate] -- first run names the phone, seeded from Build.MODEL and sent through
# SET-DEVICE-LABEL, under javac (NWP-20261114-28).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md decides that the name is set at first-boot setup, in the
# device-passphrase step (2026-09-12, NWP-20260912-01: "The name field goes there and nothing moves"), seeded from
# Build.MODEL (#37, 2026-10-22). The agent keeps it (G-07, NWP-20261114-24: the gate-only SET-DEVICE-LABEL verb and
# validDeviceLabel in core/agent/device_label.go). DeviceName is pure java, compiled as-is with DeviceNameCases: seed,
# valid (validDeviceLabel's rule: 1 to 40 code points after Go's TrimSpace, no control or format char), the field's
# code-point cap and the request shape.
# The PINS below check the wiring the cases cannot see, in ChooserActivity.buildOwnerEnrollScreen: the field is built
# only when firstRun, prefilled from DeviceName.seed(Build.MODEL); an invalid name shows one inline line and stops; the
# send goes through DeviceName.request on the worker thread after a good enrol and before finishFirstRun; its log line
# never prints the name; the heal form (firstRun=false) is still called once.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-device-name-java.sh            # the cases and the pins
#   bash test-device-name-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/DeviceName.java"
CASES="$root/core/chooser/tests/device-name/DeviceNameCases.java"
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

# count_in <text> <fixed-string> -> how many lines hold the string
count_in() {
  local n
  read -r n _ <<<"$(line_of "$1" "$2")"
  echo "$n"
}

DECL='final EditText devName = firstRun ? field("Shown on your other phones", false) : null;'
PREFILL='devName.setText(DeviceName.seed(android.os.Build.MODEL));'
CHECK='if (firstRun && !DeviceName.valid(nm)) {'
SEND='if (firstRun && r != OwnerVerifyForm.ENROL_FAILED && DeviceName.valid(nm)) saveDeviceName(nm);'

# suite <ChooserActivity.java> <DeviceName.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" o b s n lb le ladd lpre llab lchk lset lr lsend lui lfin chk lg nsend
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/$(basename "$cls")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.DeviceNameCases || return 1

  b=$(body "$f" 'private View buildOwnerEnrollScreen(final boolean firstRun) {')
  [ -n "$b" ] || { echo "  PIN P0 no buildOwnerEnrollScreen in $f" >&2; return 1; }
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//')
  # P1: the field is built only when firstRun: one declaration, and the label and the addView sit inside the one
  # `if (firstRun) {` block.
  n=$(count_in "$b" "$DECL")
  [ "$n" = 1 ] || { echo "  PIN P1 $n '$DECL' in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  lb=$(printf '%s\n' "$b" | awk '$0 == "        if (firstRun) {" { n++; l=NR } END { print (n == 1 ? l : 0) }')
  [ "$lb" -gt 0 ] || { echo "  PIN P1 not exactly one '        if (firstRun) {' block in buildOwnerEnrollScreen" >&2; return 1; }
  le=$(printf '%s\n' "$b" | awk -v s="$lb" 'NR > s && $0 == "        }" { print NR; exit }')
  [ -n "$le" ] || { echo "  PIN P1 the if (firstRun) block at $lb does not close" >&2; return 1; }
  read -r n ladd <<<"$(line_of "$b" 'll.addView(devName, ')"
  [ "$n" = 1 ] && [ "$lb" -lt "$ladd" ] && [ "$ladd" -lt "$le" ] || {
    echo "  PIN P1 ll.addView(devName, x$n at $ladd, want 1 inside the if (firstRun) block ($lb-$le)" >&2; return 1; }
  read -r n llab <<<"$(line_of "$b" 'setText("Name this phone");')"
  [ "$n" = 1 ] && [ "$lb" -lt "$llab" ] && [ "$llab" -lt "$le" ] || {
    echo "  PIN P1 setText(\"Name this phone\") x$n at $llab, want 1 inside the if (firstRun) block ($lb-$le)" >&2; return 1; }
  # P2: prefilled from the model, at most 40 long
  read -r n lpre <<<"$(line_of "$b" "$PREFILL")"
  [ "$n" = 1 ] && [ "$lb" -lt "$lpre" ] && [ "$lpre" -lt "$le" ] && [ "$lpre" -lt "$ladd" ] || {
    echo "  PIN P2 '$PREFILL' x$n at $lpre, want 1 inside the block, before the addView at $ladd" >&2; return 1; }
  # The cap counts code points (DeviceName.cap, its cases above); LengthFilter counts UTF-16 units (RF-001).
  n=$(count_in "$b" 'devName.setFilters(new android.text.InputFilter[] { DeviceName::cap });')
  [ "$n" = 1 ] || { echo "  PIN P2 $n devName.setFilters(... DeviceName::cap ...) in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  n=$(count_in "$b" 'LengthFilter')
  [ "$n" = 0 ] || { echo "  PIN P2 $n LengthFilter in buildOwnerEnrollScreen, want 0 (it counts UTF-16 units)" >&2; return 1; }
  # P3: an invalid name shows the one inline line and stops, before Set disables itself
  read -r n lchk <<<"$(line_of "$b" "$CHECK")"
  [ "$n" = 1 ] || { echo "  PIN P3 $n '$CHECK' in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  chk=$(printf '%s\n' "$b" | sed -n "${lchk}p")
  case "$chk" in *'StatusLine.error(msg, DeviceName.INVALID_LINE); return; }'*) ;;
    *) echo "  PIN P3 the inline check does not show DeviceName.INVALID_LINE and return: $chk" >&2; return 1 ;; esac
  read -r n lset <<<"$(line_of "$b" 'set.setEnabled(false)')"
  [ "$n" = 1 ] && [ "$lchk" -lt "$lset" ] || {
    echo "  PIN P3 the inline check at $lchk is not before set.setEnabled(false) at $lset (x$n)" >&2; return 1; }
  # P4: one send, behind a good enrol and a valid name
  nsend=$(count_in "$b" 'saveDeviceName(')
  [ "$nsend" = 1 ] || { echo "  PIN P4 $nsend saveDeviceName( in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  read -r n lsend <<<"$(line_of "$b" "$SEND")"
  [ "$n" = 1 ] || { echo "  PIN P4 the send is not '$SEND'" >&2; return 1; }
  # P5: enrollOwner < the send < runOnUiThread( < finishFirstRun();
  read -r n lr <<<"$(line_of "$b" 'final int r = enrollOwner(a);')"
  [ "$n" = 1 ] || { echo "  PIN P5 $n 'final int r = enrollOwner(a);', want 1" >&2; return 1; }
  read -r n lui <<<"$(line_of "$b" 'runOnUiThread(')"
  [ "$n" = 1 ] || { echo "  PIN P5 $n runOnUiThread( in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  read -r n lfin <<<"$(line_of "$b" 'finishFirstRun();')"
  [ "$n" = 1 ] || { echo "  PIN P5 $n finishFirstRun(); in buildOwnerEnrollScreen, want 1" >&2; return 1; }
  [ "$lr" -lt "$lsend" ] && [ "$lsend" -lt "$lui" ] && [ "$lui" -lt "$lfin" ] || {
    echo "  PIN P5 order: enrollOwner $lr, send $lsend, runOnUiThread $lui, finishFirstRun $lfin -- want that order" >&2
    return 1; }
  # P6: the send builds its request with DeviceName.request, the one place the verb is spelt
  s=$(body "$f" 'private void saveDeviceName(String nm) {')
  [ -n "$s" ] || { echo "  PIN P6 no saveDeviceName in $f" >&2; return 1; }
  n=$(count_in "$s" 'DaemonSocket.roundTrip(DeviceName.request(nm), ')
  [ "$n" = 1 ] || { echo "  PIN P6 $n DaemonSocket.roundTrip(DeviceName.request(nm), in saveDeviceName, want 1" >&2; return 1; }
  n=$(grep -c 'DeviceName\.request(' "$f" || true)
  [ "$n" = 1 ] || { echo "  PIN P6 $n DeviceName.request( in $f, want 1" >&2; return 1; }
  n=$(grep -c '"SET-DEVICE-LABEL' "$f" || true)
  [ "$n" = 0 ] || { echo "  PIN P6 $n \"SET-DEVICE-LABEL literal(s) in $f, want 0 (use DeviceName.request)" >&2; return 1; }
  # P7: the log line never prints the name (string literals stripped, then no nm)
  lg=$(printf '%s\n' "$s" | tr '\n' ' ' | perl -ne 'print "$1\n" while /(Log\.\w+\([^;]*;)/g' | perl -pe 's/"(?:[^"\\]|\\.)*"/""/g')
  [ -n "$lg" ] || { echo "  PIN P7 no Log. call in saveDeviceName" >&2; return 1; }
  case " $lg " in *[^A-Za-z0-9_]nm[^A-Za-z0-9_]*)
    echo "  PIN P7 the log line in saveDeviceName prints the name: $lg" >&2; return 1 ;; esac
  # P8: the heal form is still the false call, once
  n=$(grep -cF 'setContentView(buildOwnerEnrollScreen(false));' "$f" || true)
  [ "$n" = 1 ] || { echo "  PIN P8 $n setContentView(buildOwnerEnrollScreen(false)); in $f, want 1" >&2; return 1; }
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
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/DeviceName.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 the field shown when !firstRun' act 's/firstRun \? (field\("Shown on your other phones", false\)) : null;/$1;/; s/if \(firstRun\) \{(\n[ \t]*TextView nl)/if (true) {$1/'
mut 'M2 no prefill' act 's/\n[ \t]*devName\.setText\(DeviceName\.seed\(android\.os\.Build\.MODEL\)\);//'
mut 'M3 the send after finishFirstRun' act 's/\n([ \t]*)(if \(firstRun && r != OwnerVerifyForm\.ENROL_FAILED && DeviceName\.valid\(nm\)\) saveDeviceName\(nm\);)[^\n]*//; s/(if \(firstRun\) \{ finishFirstRun\(\); \})/$1 if (firstRun && r != OwnerVerifyForm.ENROL_FAILED && DeviceName.valid(nm)) saveDeviceName(nm);/'
mut 'M4a invalid names sent: the send guard dropped' act 's/ && DeviceName\.valid\(nm\)\) saveDeviceName/) saveDeviceName/'
mut 'M4b invalid names sent: the inline check removed' act 's/\n[ \t]*if \(firstRun && !DeviceName\.valid\(nm\)\) \{[^\n]*//'
mut 'M5 request drops the trailing newline' cls 's/\+ trim\(label\) \+ "\\n";/+ trim(label);/'
mut 'M6 seed returns the untrimmed model' cls 's/valid\(model\) \? trim\(model\) : ""/valid(model) ? model : ""/'
mut 'M7 valid counts chars, not code points' cls 's/int n = t\.codePointCount\(0, t\.length\(\)\);/int n = t.length();/'
mut 'M8 valid allows a tab' cls "s/if \\(cp == ' '\\) return true;/if (cp == ' ' || cp == '\\\\t') return true;/"
mut 'M9 valid allows 41 code points' cls 's/n > MAX\)/n > MAX + 1)/'
mut 'M10 the send through daemonCmd (a second newline)' act 's/DaemonSocket\.roundTrip\(DeviceName\.request\(nm\), 8000\)/daemonCmd(DeviceName.request(nm))/'
mut 'M11 the log prints the name' act 's/(rep\.isEmpty\(\) \? "no reply" : rep\) )\+ "\)"\);/$1+ " " + nm + ")");/'
mut 'M12 the send on any enrol result' act 's/r != OwnerVerifyForm\.ENROL_FAILED && DeviceName\.valid\(nm\)\) saveDeviceName/DeviceName.valid(nm)) saveDeviceName/'
mut 'M13 the request spelt in the chooser' act 's/DeviceName\.request\(nm\), 8000/"SET-DEVICE-LABEL\\n" + nm + "\\n", 8000/'
mut 'M14 the field capped by LengthFilter (UTF-16 units)' act 's/\{ DeviceName::cap \}/{ new android.text.InputFilter.LengthFilter(DeviceName.MAX) }/'
mut 'M15 cap counts UTF-16 units' cls 's/if \(Character\.codePointCount\(source, start, end\) <= room\) return null;/if (end - start <= room) return null;/'
mut 'M16 cap cuts by UTF-16 units' cls 's/Character\.offsetByCodePoints\(source, start, room\)/start + room/'
mut 'M17 trim by Java whitespace (takes U+001C, leaves U+0085)' cls 's/(static boolean space\(int cp\) \{)/$1 if (true) return Character.isWhitespace(cp) || Character.isSpaceChar(cp);/'
mut 'M18 trim leaves U+0085' cls 's/ case 0x85://'
echo "== $fails mutation(s) not convicted"
[ "$fails" = 0 ]
