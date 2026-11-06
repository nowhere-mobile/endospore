#!/usr/bin/env bash
# test-save-status-line-java.sh [--mutate] -- the Profile screen's save status line, run under javac (NWP-20261104-09).
#
# WHY THIS IS COMMITTED. After a failed sign-out the Profile line said "Signed in · not saved yet this session", which
# hid that a save had just been tried and failed (lynx 2026101402: Wi-Fi cut, GET-SYNC-STATUS answered STALE). Q058
# (docs/product-decisions.md) decided the words: a failed save is soft red and says so, a held-back one is plain grey.
# SaveStatusLine holds the words (pure, java.lang only) and is compiled here with its cases; source pins over
# ProfileActivity.showConfirm check that the SEAL-DELTA verdict reaches it and that an error line is painted through
# StatusLine.error.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-save-status-line-java.sh            # the cases and the source pins
#   bash test-save-status-line-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${SAVE_STATUS_LINE_SRC:-$SRC/SaveStatusLine.java}"
PROFILE="${PROFILE_SRC:-$SRC/ProfileActivity.java}"
RUN="$root/core/chooser/tests/save-status-line/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

# suite <SaveStatusLine.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" out rc
  [ -f "$src" ] || { echo "  FAIL  SaveStatusLine.java does not exist (the line's words are not lifted)" >&2; return 1; }
  out=$(bash "$RUN" "$src" 2>&1); rc=$?
  echo "$out"
  return "$rc"
}

# source_check <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local profile="$1" body bad=0 n
  body=$(awk '/private void showConfirm\(\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }' "$profile")
  [ -n "$body" ] || { echo "  FAIL  showConfirm not found in $profile" >&2; return 1; }
  n=$(printf '%s\n' "$body" | grep -cF 'daemonLenReply("SEAL-DELTA\n"')
  [ "$n" -eq 1 ] || { echo "  FAIL  showConfirm reads SEAL-DELTA $n times, want 1 (control)" >&2; bad=1; }
  local pin
  for pin in \
    'final String verdict = o.optString("verdict", "");' \
    'final String line = SaveStatusLine.text(run, lastOK > 0 ? fmtAgo(lastOK) : null, verdict);' \
    'final boolean err = run.isEmpty() && SaveStatusLine.isError(verdict);' \
    'runOnUiThread(() -> { if (err) StatusLine.error(stv, line); else stv.setText(line); });'; do
    n=$(printf '%s\n' "$body" | grep -cF -- "$pin")
    [ "$n" -eq 1 ] || { echo "  FAIL  showConfirm holds this line $n times, want 1: $pin" >&2; bad=1; }
  done
  n=$(printf '%s\n' "$body" | grep -cF 'not saved yet this session')
  [ "$n" -eq 0 ] || { echo "  FAIL  showConfirm still holds the not-saved line inline ($n)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | grep -cF 'stv.setOnClickListener(v -> showYourData());')
  [ "$n" -eq 1 ] || { echo "  FAIL  the line no longer opens Your data ($n)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$PROFILE" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates SaveStatusLine.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/SaveStatusLine.java"
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
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ProfileActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$PROFILE" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$PROFILE" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 refused worded as a failed save" 's/last save held back/last save failed/' || fails=$((fails+1))
mut "M2 saved-ago variant dropped" 's/return saved \? "Signed in · saved " \+ savedAgo \+ " · last try failed" : /return /' || fails=$((fails+1))
mut "M3 run no longer first" 's/(        if \(run != null[^\n]*\n)(.*?)(        if \(saved\))/$2$1$3/s' || fails=$((fails+1))
mut "M4 isError true for refused" 's/"fail"\.equals\(verdict\) \|\| "nocredit"\.equals\(verdict\)/"fail".equals(verdict) || "nocredit".equals(verdict) || "refused".equals(verdict)/' || fails=$((fails+1))
mutsrc "S1 the run guard dropped (red saving now while a failed save is retried)" 's/run\.isEmpty\(\) && //' || fails=$((fails+1))
mutsrc "S2 a failure line painted grey" 's/if \(err\) StatusLine\.error\(stv, line\); else stv\.setText\(line\);/stv.setText(line);/' || fails=$((fails+1))
mutsrc "S3 SaveStatusLine.text handed \"\" for the verdict" 's/(SaveStatusLine\.text\(run, lastOK > 0 \? fmtAgo\(lastOK\) : null, )verdict\)/$1"")/' || fails=$((fails+1))
mutsrc "S4 the verdict not read" 's/o\.optString\("verdict", ""\)/""/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
