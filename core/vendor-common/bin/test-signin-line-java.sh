#!/usr/bin/env bash
# test-signin-line-java.sh [--mutate] -- Your apps says where an app's sign-in lives, under javac (NWP-20261114-27).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md #44 (dn-1104 #5, Q081, 2026-10-22) puts one line on Your apps that
# states the NWP-20260830-03 rule (Keystore keys roam with app data, with no per-app switch). The line is
# SignInCopy.YOUR_APPS_LINE, pure java, compiled as-is with SignInLineCases: it is the decided text byte for byte, and
# it never says an app "stays signed in" (Q081). The PINS below check the wiring the cases cannot see: showYourApps
# adds a view holding SignInCopy.YOUR_APPS_LINE exactly once, after the intro `note` and before the re-archive row.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-signin-line-java.sh            # the cases and the pins
#   bash test-signin-line-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/SignInCopy.java"
CASES="$root/core/chooser/tests/signin-line/SignInLineCases.java"
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

# suite <ProfileActivity.java> <SignInCopy.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" b o v nset nadd lnote lv lrc cnote crc
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/$(basename "$cls")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.SignInLineCases || return 1

  b=$(body "$f" 'private void showYourApps()')
  [ -n "$b" ] || { echo "  PIN P0 no showYourApps in $f" >&2; return 1; }
  b=$(printf '%s\n' "$b" | grep -v '^[[:space:]]*//')
  # P1: exactly one view is given SignInCopy.YOUR_APPS_LINE; v is that view
  nset=$(printf '%s\n' "$b" | grep -c 'setText(SignInCopy\.YOUR_APPS_LINE)' || true)
  [ "$nset" = 1 ] || {
    echo "  PIN P1 $nset setText(SignInCopy.YOUR_APPS_LINE) in showYourApps, want 1" >&2; return 1; }
  v=$(printf '%s\n' "$b" | perl -ne 'print "$1\n" if /([A-Za-z_]\w*)\.setText\(SignInCopy\.YOUR_APPS_LINE\)/')
  [ -n "$v" ] || { echo "  PIN P1 no view variable holds SignInCopy.YOUR_APPS_LINE" >&2; return 1; }
  # P2: that view is added to ll exactly once
  nadd=$(printf '%s\n' "$b" | grep -cE "ll\\.addView\\($v[,)]" || true)
  [ "$nadd" = 1 ] || { echo "  PIN P2 $nadd ll.addView($v in showYourApps, want 1" >&2; return 1; }
  # P3: it is added after the intro `note` and before the re-archive row, each of those added exactly once
  read -r cnote lnote <<<"$(line_of "$b" 'll.addView(note,')"
  read -r crc lrc <<<"$(line_of "$b" 'll.addView(rcRow,')"
  lv=$(printf '%s\n' "$b" | grep -nE "ll\\.addView\\($v[,)]" | cut -d: -f1)
  [ "$cnote" = 1 ] && [ "$crc" = 1 ] || {
    echo "  PIN P3 ll.addView(note, x$cnote and ll.addView(rcRow, x$crc in showYourApps, want 1 each" >&2; return 1; }
  [ "$lnote" -lt "$lv" ] && [ "$lv" -lt "$lrc" ] || {
    echo "  PIN P3 order: note at $lnote, $v at $lv, rcRow at $lrc -- want note < $v < rcRow" >&2; return 1; }
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
  d=$(mktemp -d -p "$W"); a="$d/ProfileActivity.java"; c="$d/SignInCopy.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'M1 the line says apps stay signed in' cls \
  's/"An app\x27s sign-in travels with its data\.([^"]*)"/"Apps stay signed in from one sign-in to the next.$1"/'
mut 'M2 the view is never added' act 's/\n[ \t]*ll\.addView\(signIn, silp\);//'
mut 'M3 the view is added after the app list' act \
  's/\n([ \t]*)ll\.addView\(signIn, silp\);//; s/(\n([ \t]*)ll\.addView\(list, new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);)(?![\s\S]*private void showYourApps\(\))/$1\n$2ll.addView(signIn, silp);/'
mut 'M4 the text is inlined instead of the constant' act \
  's/signIn\.setText\(SignInCopy\.YOUR_APPS_LINE\)/signIn.setText("An app\x27s sign-in travels with its data. To sign out of an app, sign out inside it.")/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
