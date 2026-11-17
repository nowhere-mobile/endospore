#!/usr/bin/env bash
# test-signin-loss-sheets-java.sh [--mutate] -- the gate's two sign-in loss screens on the shared bottom sheet, run under
# javac (NWP-20261206-09; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to
# one bottom-sheet design", slice 3, the gate part 1).
#
# WHY THIS IS COMMITTED. Design A (Chester, 2026-11-08) says a data-loss warning is amber, its green button is the safe
# way out, the risky choice is red-outlined and a button names its action, never OK or Cancel. The two screens are the
# warning before a sign-in ends a locked session (ChooserActivity.confirmSupersedeLoss) and "Couldn't load your data"
# (ChooserActivity.offerSnapshotRecovery). SigninLossSheets holds their models. It is pure java.util and is compiled here
# with PopupSheet, the cases, and supersedeLossTitle / supersedeLossContext / supersedeLossLines lifted out of
# ChooserActivity, so the warning is checked exactly as the gate builds it. Its words, the button labels included, must
# be true of a stored session and a throwaway alike (blind login: no existence oracle; docs/product-decisions.md
# 2026-10-16 "warn and tell", 2026-11-02 #3). Source pins (comments stripped) hold what the cases cannot:
#   S1 confirmSupersedeLoss and offerSnapshotRecovery hold no AlertDialog.Builder;
#   S2 the warning's slot 0 (Keep that session) only counts down, slot 1 (Continue) sets go[0] = true and then counts
#      down, and setCancelable(false) follows, so Back and a touch outside do nothing;
#   S3 the offer's three actions in order (Try again, Restore last good version, Not now), assigned to snapshotOffer,
#      which closeScreenOffSurfaces dismisses at a screen-off;
#   S4 SheetDialog.confirm returns the dialog it shows (the two callers above keep it): confirm returns
#      confirmSheet(ctx, m, actions, onLink, false), which ends show(dlg, panel, held); return dlg; (NWP-20261206-17
#      put the body in confirmSheet).
# The rest of the warning (the wait, its two-minute limit, the keep path) is core/vendor-common/bin/test-supersede-credit-java.sh;
# the screen-off close is core/vendor-common/bin/test-signin-clear-java.sh.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-signin-loss-sheets-java.sh            # the cases + the pins
#   bash test-signin-loss-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEETS="$SRC/SigninLossSheets.java"
DIALOG="$SRC/SheetDialog.java"
ACT="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/signin-loss-sheets/SigninLossSheetsCases.java"
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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: the source pins need python3, and there is none" >&2; exit 2; }
for f in "$POPUP" "$CASES"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# The source pins, on comment-stripped copies. Method bodies are cut out by string-aware brace matching; a failed
# extraction is a FAIL, never a pass.
PINS=$(mktemp -p "$W") || exit 2
cat >"$PINS" <<'PY'
import re, sys

act = open(sys.argv[1], encoding="utf-8").read()
dlg = open(sys.argv[2], encoding="utf-8").read()

def strip(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * s.count("\n", i, j))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

def close(s, o):
    """index of the } that matches the { at o, skipping literals; -1 when unmatched"""
    d, i, n = 0, o, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if c == "{":
            d += 1
        elif c == "}":
            d -= 1
            if d == 0:
                return i
        i += 1
    return -1

def body(s, anchor):
    """the normalized text of the method whose declaration starts with anchor, to its closing brace; None when the
    anchor is missing, repeated, or its block is not found"""
    a = s.find(anchor)
    if a < 0 or s.find(anchor, a + 1) >= 0:
        return None
    o = s.find("{", a)
    c = -1 if o < 0 else close(s, o)
    return None if c < 0 else re.sub(r"\s+", " ", s[a:c + 1]).strip()

a, d = strip(act), strip(dlg)
fails = []
def ok(cond, what):
    if not cond:
        print("FAIL " + what)
        fails.append(what)

warn = body(a, "private boolean confirmSupersedeLoss(")
offer = body(a, "private void offerSnapshotRecovery(")
conf = body(d, "static Dialog confirm(")
sheet = body(d, "private static Dialog confirmSheet(")

ok(warn is not None and offer is not None and "AlertDialog.Builder" not in warn and "AlertDialog.Builder" not in offer,
   "S1 no AlertDialog.Builder in confirmSupersedeLoss or offerSnapshotRecovery")

S2 = ("shown[0] = SheetDialog.confirm(this, SigninLossSheets.supersede(supersedeLossTitle(), supersedeLossContext(),"
      " supersedeLossLines(creditLost)), new Runnable[] { () -> answered.countDown(), () -> { go[0] = true;"
      " answered.countDown(); } }, null); if (shown[0] != null) shown[0].setCancelable(false);")
ok(warn is not None and warn.count(S2) == 1,
   "S2 the warning: slot 0 only counts down, slot 1 sets go[0] then counts down, setCancelable(false) follows")

S3 = ("snapshotOffer = SheetDialog.confirm(this, SigninLossSheets.snapshotOffer(), new Runnable[] {"
      " () -> roamLogin(name, pw, false), () -> doGateRollback(name, pw),"
      " () -> { hideRestore(); if (result != null) result.setText(\"\"); } }, null);")
ok(offer is not None and offer.count(S3) == 1,
   "S3 the offer: Try again, Restore, Not now in order, assigned to snapshotOffer")

ok(conf is not None and "return confirmSheet(ctx, m, actions, onLink, false);" in conf and sheet is not None
   and "if (m == null) return null;" in sheet and sheet.endswith("show(dlg, panel, held); return dlg; }"),
   "S4 SheetDialog.confirm returns the dialog it shows")

print("pins: %d of 4 hold" % (4 - len(fails)))
sys.exit(1 if fails else 0)
PY

# lift <ChooserActivity.java> <out .java> -> SupersedeCopy: the three copy helpers, private static dropped. 1 when one
# is missing (never a silent skip).
lift() {
  local act="$1" out="$2" m
  {
    echo "package com.nowhere.chooser;"
    echo "final class SupersedeCopy {"
    for m in supersedeLossTitle supersedeLossContext supersedeLossLines; do
      # from the method's signature line to the brace that closes it (core/chooser/tests/supersede-credit/run.sh)
      awk -v m="$m" '
        !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
        on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
      ' "$act" | sed 's/private static/static/'
    done
    echo "}"
  } > "$out"
  for m in supersedeLossTitle supersedeLossContext supersedeLossLines; do
    grep -q " $m(" "$out" || { echo "FAIL lift: $m is not in ChooserActivity.java"; return 1; }
  done
}

# suite <PopupSheet.java> <SigninLossSheets.java> <SheetDialog.java> <ChooserActivity.java> -> 0 pass, 1 a case or a pin
# failed (the only code that convicts a mutant), 3 it did not compile.
suite() {
  local popup="$1" sheets="$2" dialog="$3" act="$4" d out rc=0
  [ -f "$sheets" ] || { echo "FAIL SigninLossSheets.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src" "$d/out"
  cp "$popup" "$d/src/PopupSheet.java"
  cp "$sheets" "$d/src/SigninLossSheets.java"
  cp "$CASES" "$d/src/SigninLossSheetsCases.java"
  if ! lift "$act" "$d/src/SupersedeCopy.java"; then rm -rf "$d"; return 1; fi
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SigninLossSheetsCases 2>&1) || rc=1
  echo "$out"
  rm -rf "$d"
  python3 -I "$PINS" "$act" "$dialog" || rc=1
  return "$rc"
}

echo "== SigninLossSheets, PopupSheet, the gate's supersede copy; pins S1-S4"
suite "$POPUP" "$SHEETS" "$DIALOG" "$ACT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "ok: cases + pins S1-S4"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# MUT_DIR / MUT_FILE: the last mutant's copy, kept until the next mut so a second check can read it.
MUT_DIR=""; MUT_FILE=""
mut() { # mut <label> <sheets|dialog|act> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  [ -n "$MUT_DIR" ] && rm -rf "$MUT_DIR"
  MUT_DIR=""; MUT_FILE=""
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheets) orig="$SHEETS" ;; dialog) orig="$DIALOG" ;; *) orig="$ACT" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheets) out=$(suite "$POPUP" "$c" "$DIALOG" "$ACT" 2>&1); rc=$? ;;
    dialog) out=$(suite "$POPUP" "$SHEETS" "$c" "$ACT" 2>&1); rc=$? ;;
    *) out=$(suite "$POPUP" "$SHEETS" "$DIALOG" "$c" 2>&1); rc=$? ;;
  esac
  MUT_DIR="$d"; MUT_FILE="$c"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL $3"*) echo "  convicted $1 -- FAIL $3"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
# also <label> <what> <rc> <output> <needle> -> 0 when a second suite run on the same mutant failed with the needle.
also() {
  if [ "$3" -ne 0 ] && case "$4" in *"$5"*) true ;; *) false ;; esac; then echo "            $1 -- also $2"; return 0; fi
  echo "  WRONG     $1 -- $2 did not convict it (rc=$3)"; printf '%s\n' "$4" | tail -3
  return 1
}
T=$'\t'
fails=0
mut "M1 Continue is green" sheets "supersede (credit): Continue is RED_OUTLINED" \
  's/(SUPERSEDE_CONTINUE, PopupSheet\.Style\.)RED_OUTLINED/${1}GREEN_FILLED/' || fails=$((fails+1))
mut "M2 the warning's actions swapped" act "S2 the warning" \
  's/new Runnable\[\] \{ \(\) -> answered\.countDown\(\), \(\) -> \{ go\[0\] = true; answered\.countDown\(\); \} \}/new Runnable[] { () -> { go[0] = true; answered.countDown(); }, () -> answered.countDown() }/' || fails=$((fails+1))
if mut "M3 the warning can be dismissed (setCancelable(false) removed)" act "S2 the warning" \
  's/\n[ \t]*if \(shown\[0\] != null\) shown\[0\]\.setCancelable\(false\);//'; then
  out=$(SC_TMP=$W JAVAC=$JAVAC JAVA=$JAVA bash "$root/core/chooser/tests/supersede-credit/run.sh" "$MUT_FILE" 2>&1); rc=$?
  also "M3" "test-supersede-credit-java.sh's pin (J13)" "$rc" "$out" "FAIL pinned: confirmSupersedeLoss" || fails=$((fails+1))
else
  fails=$((fails+1))
fi
mut "M4 the old J22 on the green label" sheets "supersede (credit): no word, labels included" \
  's/SUPERSEDE_KEEP = "Keep that session";/SUPERSEDE_KEEP = "Keep that session: signing out of it tries to save again";/' || fails=$((fails+1))
mut "M5 Restore is green" sheets "snapshotOffer: Restore last good version is RED_OUTLINED" \
  's/(SNAPSHOT_RESTORE, PopupSheet\.Style\.)RED_OUTLINED/${1}GREEN_FILLED/' || fails=$((fails+1))
mut "M6 Try again and Restore actions swapped" act "S3 the offer" \
  's/\(\) -> roamLogin\(name, pw, false\),(\s*)\(\) -> doGateRollback\(name, pw\),/() -> doGateRollback(name, pw),$1() -> roamLogin(name, pw, false),/' || fails=$((fails+1))
mut "M7 a line dropped" sheets "snapshotOffer: context and lines joined equal today's message" \
  's/, new PopupSheet\.Line\(SNAPSHOT_LINE_DAMAGED, null\)//' || fails=$((fails+1))
mut "M8 confirm returns null" dialog "S4 SheetDialog.confirm returns" \
  's/(private static Dialog confirmSheet\(.*?show\(dlg, panel, held\);\n\s*)return dlg;/${1}return null;/s' || fails=$((fails+1))
if mut "M9 a Cancel builder put back" act "S1 no AlertDialog.Builder" \
  's/(\/\/ NWP-20261118-07: kept so a screen-off closes it \(closeScreenOffSurfaces\)\n)/$1            new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();\n/'; then
  lint=$(mktemp -d -p "$W")
  cp "$SRC"/*.java "$lint/"
  cp "$MUT_FILE" "$lint/ChooserActivity.java"
  out=$(TMPDIR=$W SRC_DIR=$lint bash "$root/core/chooser/test-popup-rules.sh" 2>&1); rc=$?
  rm -rf "$lint"
  also "M9" "test-popup-rules.sh NEW" "$rc" "$out" \
    "NEW: ChooserActivity.java${T}offerSnapshotRecovery${T}R1${T}Cancel (baseline 0, found 1)" || fails=$((fails+1))
else
  fails=$((fails+1))
fi
[ -n "$MUT_DIR" ] && rm -rf "$MUT_DIR"
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
