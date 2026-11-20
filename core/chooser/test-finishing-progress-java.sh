#!/usr/bin/env bash
# test-finishing-progress-java.sh [--mutate] -- Finishing up shows which Installed app is installing, under javac
# (NWP-20261208-25).
#
# WHY THIS IS COMMITTED. The post-restore finish painted "Finishing up…" at 95 and nothing moved until the switch's
# 100, while installRoamedAppCode installed every Installed app one PackageInstaller session at a time. The approved
# words (Chester, 2026-11-17, NWP-20261116-48): "Installing <app> (<i> of <n>)" under the status line, the bar moving
# 95..99 as the installs finish (100 stays with the switch, D7), and the status line "Finishing up… — <N>%".
# FinishingProgress (pct, status, line) is the pure rule, run here; ChooserActivity's 95 and 100 paints, the
# pre-pass count, the per-install line, the final post, the GONE resets and appLabelOf's no-log rule are pinned in the
# source, comments stripped.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-finishing-progress-java.sh            # the cases
#   bash test-finishing-progress-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FP="$HERE/src/com/nowhere/chooser/FinishingProgress.java"
CA="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/finishing-progress/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$FP" ] || { echo "FAIL: missing $FP" >&2; exit 2; }
[ -f "$CA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CA or $RUN" >&2; exit 2; }

suite() { bash "$RUN" "$1" "$2"; } # <FinishingProgress.java> <ChooserActivity.java>

echo "== $FP"
suite "$FP" "$CA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the cases; one that does not apply or compile is a failure)"
# run_mut <label> <fp|ca> <perl-expr>: prints the suite's exit status on stdout, or INERT / ERROR.
run_mut() {
  local d f fp ca rc; d=$(mktemp -d -p "$W"); fp="$d/FinishingProgress.java"; ca="$d/ChooserActivity.java"
  cp "$FP" "$fp"; cp "$CA" "$ca"
  if [ "$2" = fp ]; then f="$fp"; else f="$ca"; fi
  if ! perl -0pi -e "$3" "$f"; then rm -rf "$d"; echo ERROR; return; fi
  if cmp -s "$FP" "$fp" && cmp -s "$CA" "$ca"; then rm -rf "$d"; echo INERT; return; fi
  suite "$fp" "$ca" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  echo "$rc"
}
mut() { # mut <label> <fp|ca> <perl-expr>: the mutant must be CONVICTED (rc 1)
  local r; r=$(run_mut "$@")
  case "$r" in
    ERROR) echo "  ERROR     $1 -- perl failed on the mutation"; return 1 ;;
    INERT) echo "  INERT     $1 -- the mutation changed nothing"; return 1 ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$r)"; return 1 ;;
  esac
}
control() { # control <label> <fp|ca> <perl-expr>: a change the cases must NOT notice (rc 0)
  local r; r=$(run_mut "$@")
  case "$r" in
    0) echo "  survived  $1 (control)"; return 0 ;;
    *) echo "  FAILED    $1 (control) -- want rc 0, got $r"; return 1 ;;
  esac
}
fails=0
mut "F1 pct reaches 100 (C1)" fp 's/95 \+ \(4 \* d\)/95 + (5 * d)/' || fails=$((fails+1))
mut "F2 pct ignores done (C1)" fp 's/95 \+ \(4 \* d\) \/ n/95 + (4 * 0) \/ n/' || fails=$((fails+1))
mut "F3 status drops the em dash (C2)" fp 's/\xe2\x80\xa6 \xe2\x80\x94 "/\xe2\x80\xa6 "/' || fails=$((fails+1))
mut "F4 line swaps i and n (C3)" fp 's/\+ i \+ " of " \+ n \+/+ n + " of " + i +/' || fails=$((fails+1))
mut "F5 the 95 paint back to the bare Finishing up words (P1)" ca 's/result\.setText\(FinishingProgress\.status\(95\)\)/result.setText("Finishing up\xe2\x80\xa6")/' || fails=$((fails+1))
mut "F6 hideRestore keeps installLine (P4)" ca 's/(            result\.setText\(""\);\n)            if \(installLine != null\) installLine\.setVisibility\(View\.GONE\);[^\n]*\n/$1/' || fails=$((fails+1))
mut "F7 the FinishingProgress.line( call removed (P3)" ca 's/FinishingProgress\.line\(appLabelOf\(labelApk, pkg\), at, n\)/pkg/' || fails=$((fails+1))
mut "F8 the pre-pass counts deferred rows (P3)" ca 's/if \(r == null \|\| r\.deferred\) continue;/if (r == null) continue;/' || fails=$((fails+1))
mut "F9 appLabelOf logs the label (P5)" ca 's/(\n            )(return l == null \|\| )/$1android.util.Log.i("NowhereChooser", "label " + l);$1$2/' || fails=$((fails+1))
mut "F10 the finally drops its final post (P3)" ca 's/            if \(n > 0\) runOnUiThread\(\(\) -> \{[^\n]*\n(?:[^\n]*\n){3}            \}\);\n//' || fails=$((fails+1))
control "C the class comment says another word" fp 's/so a javac suite\n \*  runs it/so a javac suite\n *  executes it/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control survived" || { echo "== $fails mutation(s) not as expected"; exit 1; }
