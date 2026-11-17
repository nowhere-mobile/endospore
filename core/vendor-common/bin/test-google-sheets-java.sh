#!/usr/bin/env bash
# test-google-sheets-java.sh [--mutate] -- Turn Google Play off and Sign out of Google on the shared sheet, run under
# javac (NWP-20261206-18; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to
# one bottom-sheet design", design A, slice 3).
#
# WHY THIS IS COMMITTED. The two Google confirmations left AlertDialog for PopupSheet models in GoogleSheets. Turn Google
# Play off is a warning: its green button keeps Google Play and "Turn off" is red-outlined. Sign out of Google is
# routine, with the words docs/product-decisions.md 2026-10-21 (dn-1106 #2) decided. PopupSheet, PlayChoice,
# GoogleSignOut and GoogleSheets are pure java.util and are compiled here with their cases:
#   C1 playOff is a WARNING; "Keep Google Play" green first, "Turn off" red-outlined second;
#   C2 playOff's context and its one line, joined, are the Off dialog's message before this slice;
#   C3 signOut is ROUTINE; "Sign out of Google", the decided sentence pair, "Sign out" green, "Not now" outlined;
#   C4 neither has an OK or Cancel button;  C5 PopupSheet.violations is empty for both.
# Source pins (comments stripped, whitespace removed) hold what the cases cannot:
#   S1 confirmPlayOff and confirmGoogleSignOut hold no AlertDialog.Builder and one SheetDialog.confirm each;
#   S2 confirmPlayOff's turnPlayOff() is in slot 1 ("Turn off") and slot 0 is null;
#   S3 confirmGoogleSignOut's claim and signOutGoogle are in slot 0 ("Sign out") and slot 1 is null.
# It does NOT prove the sheets on a handset: that is the row's CLOSES WHEN, the merger's follow-up.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-google-sheets-java.sh            # the cases + the pins
#   bash test-google-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
PLAY="$SRC/PlayChoice.java"
GSO="$SRC/GoogleSignOut.java"
GSH="$SRC/GoogleSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/google-sheets/GoogleSheetsCases.java"
LINT="$root/core/chooser/test-popup-rules.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
for f in "$POPUP" "$PLAY" "$GSO" "$PA" "$CASES" "$LINT"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# pins <ProfileActivity.java> -> 0 ok, 1 a pin failed, 2 a control failed
pins() {
  python3 -I - "$1" <<'PY'
import io, re, sys

def strip_comments(src):
    """Drop line and block comments; keep string and char literals."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1]); i = j + 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' '); continue
        out.append(c); i += 1
    return ''.join(out)

def method(code, sig):
    """The member from sig to its closing brace (literals skipped), or None when sig is not there exactly once."""
    if code.count(sig) != 1: return None
    i = code.index(sig); k = code.index('{', i); d = 0; n = len(code)
    while k < n:
        c = code[k]
        if c in '"\'':
            j = k + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == '\\' else 1
            k = j + 1; continue
        if c == '{': d += 1
        elif c == '}':
            d -= 1
            if d == 0: return code[i:k + 1]
        k += 1
    return None

act = strip_comments(io.open(sys.argv[1], encoding='utf-8').read())
pconf = method(act, 'private void confirmPlayOff() {')
gconf = method(act, 'private void confirmGoogleSignOut(final android.accounts.Account acct) {')
if pconf is None or gconf is None:
    print('  CONTROL confirmPlayOff or confirmGoogleSignOut not found exactly once (or its braces do not balance)')
    sys.exit(2)
flat = lambda s: re.sub(r'\s+', '', s)
pconf, gconf = flat(pconf), flat(gconf)
fails = []
def pin(name, ok, why):
    if ok: print('  ok    ' + name)
    else: print('  PIN   ' + name + ': ' + why); fails.append(name)

for name, body in (('confirmPlayOff', pconf), ('confirmGoogleSignOut', gconf)):
    pin('S1 %s holds no AlertDialog.Builder and one SheetDialog.confirm' % name,
        'AlertDialog.Builder' not in body and body.count('SheetDialog.confirm(') == 1, body[:300])
pin('S2 confirmPlayOff: slot 0 ("Keep Google Play") is null, slot 1 ("Turn off") runs turnPlayOff()',
    pconf == 'privatevoidconfirmPlayOff(){'
             'SheetDialog.confirm(this,GoogleSheets.playOff(),newRunnable[]{null,()->turnPlayOff()},null);}', pconf[:300])
HEAD = ('privatevoidconfirmGoogleSignOut(finalandroid.accounts.Accountacct){'
        'SheetDialog.confirm(this,GoogleSheets.signOut(),newRunnable[]{()->{')
steps = ['finalStringhash=GoogleSignOut.markHash(acct.name);', 'if(GoogleSignOut.claim(hash)){',
         'newThread(()->signOutGoogle(acct,hash),"nowhere-google-signout").start();}']
at = len(HEAD) if gconf.startswith(HEAD) else -1
for s in steps:
    at = gconf.find(s, at) if at >= 0 else -1
    at = at + len(s) if at >= 0 else -1
pin('S3 confirmGoogleSignOut: slot 0 ("Sign out") claims the account and runs signOutGoogle, slot 1 is null',
    at >= 0 and gconf[at:] == '},null},null);}', gconf[:400])
sys.exit(1 if fails else 0)
PY
}

# suite <PopupSheet> <PlayChoice> <GoogleSignOut> <GoogleSheets> <ProfileActivity> -> 0 pass, 1 a case or pin failed
# (the only code that convicts a mutant), 2 a control failed, 3 it did not compile.
suite() {
  local popup="$1" play="$2" gso="$3" gsh="$4" pa="$5" d rc
  [ -f "$gsh" ] || { echo "  FAIL  GoogleSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$play" "$d/src/com/nowhere/chooser/PlayChoice.java"
  cp "$gso" "$d/src/com/nowhere/chooser/GoogleSignOut.java"
  cp "$gsh" "$d/src/com/nowhere/chooser/GoogleSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GoogleSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GoogleSheetsCases; rc=$?
  rm -rf "$d"
  [ "$rc" -eq 0 ] || { echo "  FAIL  GoogleSheetsCases" >&2; return 1; }
  pins "$pa"
}

echo "== GoogleSheets, PlayChoice, GoogleSignOut, PopupSheet and ProfileActivity"
suite "$POPUP" "$PLAY" "$GSO" "$GSH" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin; a mutant that does not apply or compile proves nothing)"
fails=0
# mut <label> <gsh|pa> <perl-expr> -> the mutant copy must fail the suite with rc 1. MUT_COPY is left set to it.
mut() {
  local label="$1" which="$2" expr="$3" d m g p rc
  d=$(mktemp -d -p "$W"); g="$GSH"; p="$PA"
  if [ "$which" = gsh ]; then m="$d/GoogleSheets.java"; perl -0pe "$expr" "$GSH" > "$m" || { echo "  ERROR     $label -- perl failed"; return 1; }
    cmp -s "$GSH" "$m" && { echo "  INERT     $label"; return 1; }; g="$m"
  else m="$d/ProfileActivity.java"; perl -0pe "$expr" "$PA" > "$m" || { echo "  ERROR     $label -- perl failed"; return 1; }
    cmp -s "$PA" "$m" && { echo "  INERT     $label"; return 1; }; p="$m"
  fi
  MUT_COPY="$m"
  suite "$POPUP" "$PLAY" "$GSO" "$g" "$p" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  convicted $label"; return 0 ;;
    *) echo "  BROKEN    $label (rc=$rc)"; return 1 ;;
  esac
}
mut "M1 \"Turn off\" made green (C1, C5)" gsh 's/\Q(PlayChoice.OFF_CONFIRM, PopupSheet.Style.RED_OUTLINED)\E/(PlayChoice.OFF_CONFIRM, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "M2 the playOff actions swapped (S2)" pa 's/\Qnew Runnable[] { null, () -> turnPlayOff() }\E/new Runnable[] { () -> turnPlayOff(), null }/' || fails=$((fails+1))
mut "M3 the signOut actions swapped (S3)" pa 's/\QGoogleSheets.signOut(), new Runnable[] { () -> {\E/GoogleSheets.signOut(), new Runnable[] { null, () -> {/; s/\Q}, null }, null);\E/} }, null);/' || fails=$((fails+1))
mut "M4 CONFIRM's second sentence dropped from the context (C3)" gsh 's/\QGoogleSignOut.ROW_LABEL, GoogleSignOut.CONFIRM,\E/GoogleSignOut.ROW_LABEL, GoogleSignOut.CONFIRM.substring(0, GoogleSignOut.CONFIRM.indexOf(" Signing out in")),/' || fails=$((fails+1))
mut "M5 OFF_LINE dropped (C2)" gsh 's/\QArrays.asList(new PopupSheet.Line(PlayChoice.OFF_LINE, null))\E/Collections.<PopupSheet.Line>emptyList()/' || fails=$((fails+1))
mut "M6 \"Not now\" made \"Cancel\" (C3, C4)" gsh 's/\Qnew PopupSheet.Button(PopupSheet.NOT_NOW,\E/new PopupSheet.Button("Cancel",/' || fails=$((fails+1))
# M7 also runs the popup lint on a source copy that holds the mutant: it must report the builder as NEW.
if mut "M7 a Cancel AlertDialog put back in confirmPlayOff (S1)" pa 's/(\Q        SheetDialog.confirm(this, GoogleSheets.playOff(),\E[^\n]*\n)/$1        new android.app.AlertDialog.Builder(this).setTitle(PlayChoice.OFF_TITLE).setNegativeButton("Cancel", null).show();\n/'; then
  ls_dir=$(mktemp -d -p "$W")
  cp "$SRC"/*.java "$ls_dir/" && cp "$MUT_COPY" "$ls_dir/ProfileActivity.java"
  lint_out=$(SRC_DIR="$ls_dir" bash "$LINT" 2>&1); lint_rc=$?
  want="NEW: ProfileActivity.java"$'\t'"confirmPlayOff"$'\t'"R1"$'\t'"Cancel (baseline 0, found 1)"
  if [ "$lint_rc" -eq 1 ] && [[ "$lint_out" == *"$want"* ]]; then
    echo "  convicted M7 (test-popup-rules.sh reports NEW)"
  else
    echo "  SURVIVED  M7 in test-popup-rules.sh (rc=$lint_rc)"; echo "$lint_out"; fails=$((fails+1))
  fi
else
  fails=$((fails+1))
fi
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
