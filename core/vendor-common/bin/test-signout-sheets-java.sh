#!/usr/bin/env bash
# test-signout-sheets-java.sh [--mutate] -- the sign-out group's confirmations on the shared bottom sheet, run under
# javac (NWP-20261206-10; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to
# one bottom-sheet design", slice 3 part 1).
#
# WHY THIS IS COMMITTED. The update card's "Sign out and install?" and the held apps' "Release ...?" are routine sheets
# now. SignOutSheets builds their models, and OtaUpdate gives the install sheet its context and lines. Both are pure
# java.util, so this suite compiles them with PopupSheet and the cases. The cases hold the words, the tone, the buttons
# and their styles, and that OtaUpdate.installConfirm is still today's text byte for byte. Source pins (comments
# stripped) hold the two ProfileActivity methods:
#   S1 confirmSignOutAndInstall and confirmRelease hold no AlertDialog.Builder;
#   S2 confirmSignOutAndInstall shows SignOutSheets.install(local), the OTA-AFTER-LOGOFF thread in slot 0, slot 1 null;
#   S3 confirmRelease shows SignOutSheets.release(what, all), AppHeld.release(this, pkg) in slot 0, slot 1 null.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-signout-sheets-java.sh            # the cases + the pins
#   bash test-signout-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
OTA="$SRC/OtaUpdate.java"
SHEETS="$SRC/SignOutSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/signout-sheets/SignOutSheetsCases.java"
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
for f in "$CASES" "$PA" "$POPUP"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <OtaUpdate.java> <SignOutSheets.java> -> 0 pass, 1 a case failed or a class is missing (the only codes that
# convict a mutant), 3 it did not compile.
suite() {
  local ota="$1" sheets="$2" d out rc
  [ -f "$ota" ] || { echo "  FAIL  OtaUpdate.java does not exist" >&2; return 1; }
  [ -f "$sheets" ] || { echo "  FAIL  SignOutSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$ota" "$d/src/com/nowhere/chooser/OtaUpdate.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/SignOutSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SignOutSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SignOutSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  SignOutSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# after <text> <first> <then> -> 0 when <then> occurs after the first <first>.
after() { case "$1" in *"$2"*"$3"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m open
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in confirmSignOutAndInstall confirmRelease; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" confirmSignOutAndInstall)
  open='SheetDialog.confirm(this, SignOutSheets.install(local), new Runnable[] { () -> new Thread(() -> {'
  has "$b" "$open" \
    || { echo "  FAIL  S2 confirmSignOutAndInstall does not show SignOutSheets.install(local) with a thread in slot 0" >&2; bad=1; }
  after "$b" "$open" 'OTA-AFTER-LOGOFF\n1 ' \
    || { echo "  FAIL  S2 confirmSignOutAndInstall's slot 0 does not record OTA-AFTER-LOGOFF" >&2; bad=1; }
  after "$b" "$open" 'doLogoffForInstall();' \
    || { echo "  FAIL  S2 confirmSignOutAndInstall's slot 0 does not call doLogoffForInstall()" >&2; bad=1; }
  after "$b" 'doLogoffForInstall();' '}, "nowhere-signout-install").start(), null }, null);' \
    || { echo "  FAIL  S2 confirmSignOutAndInstall's slot 1 (Not now) is not null" >&2; bad=1; }

  b=$(meth "$paf" confirmRelease)
  open='SheetDialog.confirm(this, SignOutSheets.release(what, all), new Runnable[] { () -> {'
  has "$b" "$open" \
    || { echo "  FAIL  S3 confirmRelease does not show SignOutSheets.release(what, all) with an action in slot 0" >&2; bad=1; }
  after "$b" "$open" 'AppHeld.release(this, pkg);' \
    || { echo "  FAIL  S3 confirmRelease's slot 0 does not call AppHeld.release(this, pkg)" >&2; bad=1; }
  after "$b" 'AppHeld.release(this, pkg);' '}, null }, null);' \
    || { echo "  FAIL  S3 confirmRelease's slot 1 (Keep holding) is not null" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <OtaUpdate.java> <SignOutSheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when
# one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$3" || rc=1
  return "$rc"
}

echo "== SignOutSheets, OtaUpdate, PopupSheet"
check_all "$OTA" "$SHEETS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <ota|sheets|pa> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in ota) orig="$OTA" ;; sheets) orig="$SHEETS" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    ota) out=$(check_all "$c" "$SHEETS" "$PA" 2>&1); rc=$? ;;
    sheets) out=$(check_all "$OTA" "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) echo "  convicted $1 -- FAIL  $3"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
fails=0
mut "M1 the two install contexts swapped"     ota    "install(false) context"     's/\? ("You.ll be signed out first\. This[^"]*")\n(\s+): ("You.ll be signed out first, and[^"]*")/? $3\n$2: $1/' || fails=$((fails+1))
mut "M2 an install line dropped"              sheets "install(false) lines"       's/OtaUpdate\.installLines\(\)\)/OtaUpdate.installLines().subList(0, 1))/' || fails=$((fails+1))
mut "M3 \"Sign out & install\" on the button" sheets "install(false) buttons"     's/INSTALL = "Sign out and install";/INSTALL = "Sign out & install";/' || fails=$((fails+1))
mut "M4 Not now is the green button"          sheets "install(false) buttons"     's/NOT_NOW, PopupSheet\.Style\.OUTLINED/NOT_NOW, PopupSheet.Style.GREEN_FILLED/' || fails=$((fails+1))
mut "M5 \"them\" for one app"                 sheets "release one context"        's/all \? ALL : ONE/ALL/' || fails=$((fails+1))
mut "M6 Release outlined"                     sheets "release one buttons"        's/\(RELEASE, PopupSheet\.Style\.GREEN_FILLED\)/(RELEASE, PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "M7 the install thread in slot 1"         pa     "S2 confirmSignOutAndInstall does not show" 's/new Runnable\[\] \{ \(\) -> new Thread\(/new Runnable[] { null, () -> new Thread(/; s/"nowhere-signout-install"\)\.start\(\), null \}, null\);/"nowhere-signout-install").start() }, null);/' || fails=$((fails+1))
mut "M8 AppHeld.release in slot 1"            pa     "S3 confirmRelease does not show" 's/(release\(what, all\), new Runnable\[\] \{ )(\(\) -> \{.*?\n        \}), null \}, null\);/$1null, $2 }, null);/s' || fails=$((fails+1))
mut "M9 a builder back in confirmRelease"     pa     "S1 confirmRelease holds"    's/(private void confirmRelease\([^\n]*\{\n)/$1        new android.app.AlertDialog.Builder(this).show();\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
