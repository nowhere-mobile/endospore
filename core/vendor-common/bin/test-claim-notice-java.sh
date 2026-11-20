#!/usr/bin/env bash
# test-claim-notice-java.sh [--mutate] -- Profile's claim notice: the codes the profile was not told about could not be
# used, run under javac (NWP-20261208-04; docs/backlog.md, "P0: `CREATE-CODE` joins an identified purchase to
# `profileRefV2` seconds later from the same IP", slice 3, the chooser half).
#
# WHY THIS IS COMMITTED. Profile's home asks GET-CLAIM-NOTICE once per open and, on NOTICE <n>, shows one routine sheet
# whose two buttons both send CLAIM-NOTICE-SHOWN <n>. ClaimNoticeCopy is pure java.util and is compiled here with
# PopupSheet and its cases:
#   K1 count is n only for exactly "NOTICE <n>" with n a positive int, else 0 (NONE, ERR*, an unknown-verb answer);
#   K2 the two requests, byte for byte;
#   K3 the sheet: routine, one title for one code and one for more, Start or extend a plan green filled in slot 0,
#      Got it outlined in slot 1, no OK or Cancel, and PopupSheet's rules find no breach.
# Source pins over ProfileActivity (comments stripped) hold what the cases cannot:
#   P1 showConfirm sends ClaimNoticeCopy.GET_REQUEST on a new thread, once per instance (claimNoticeAsked), and opens
#      SheetDialog.confirm with ClaimNoticeCopy.sheet(n);
#   P2 both slots send ClaimNoticeCopy.ackRequest(n) on a thread, and slot 0 then calls showAddCredits();
#   P3 the sheet opens only for n > 0 and only under !isFinishing() && !isDestroyed() && shownView == confirmView.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-claim-notice-java.sh            # the cases + the pins
#   bash test-claim-notice-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
COPY="$SRC/ClaimNoticeCopy.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/claim-notice/ClaimNoticeCases.java"
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

# suite <ClaimNoticeCopy.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local copy="$1" d out rc
  [ -f "$copy" ] || { echo "  FAIL  K1-K3 ClaimNoticeCopy.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$copy" "$d/src/com/nowhere/chooser/ClaimNoticeCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ClaimNoticeCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ClaimNoticeCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  ClaimNoticeCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <declaration> -> the method's lines joined into one, spaces squeezed, from the line that starts with
# its full 4-space declaration (so a call site never matches) to its 4-space closing brace; a wrapped call still matches.
meth() {
  D="$2" awk '!f && index($0, ENVIRON["D"]) == 1 { f = 1 } f { print } f && /^    }$/ { exit }' "$1" \
    | tr '\n' ' ' | tr -s ' '
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b get open sep ack fields between rest slot0 slot1
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  b=$(meth "$paf" "    private void showConfirm(")
  [ -n "$b" ] || { echo "  FAIL  P1 showConfirm( not found" >&2; return 1; }
  get='new Thread(() -> { final int n = ClaimNoticeCopy.count(sendDaemon(ClaimNoticeCopy.GET_REQUEST));'
  open='SheetDialog.confirm(this, ClaimNoticeCopy.sheet(n), new Runnable[] {'
  sep='showAddCredits(); },'
  ack='new Thread(() -> sendDaemon(ClaimNoticeCopy.ackRequest(n))).start()'

  # P1: once per instance, the read on a new thread, then the sheet.
  fields=$(grep -c '^    private boolean claimNoticeAsked;$' "$paf")
  [ "$fields" -eq 1 ] || { echo "  FAIL  P1 claimNoticeAsked is declared $fields times, not once" >&2; bad=1; }
  if ! has "$b" "if (!claimNoticeAsked) { claimNoticeAsked = true; $get"; then
    echo "  FAIL  P1 showConfirm does not send ClaimNoticeCopy.GET_REQUEST on a new thread once per instance" >&2; bad=1
  elif ! has "${b#*"$get"}" "$open"; then
    echo "  FAIL  P1 showConfirm does not open SheetDialog.confirm with ClaimNoticeCopy.sheet(n) after the read" >&2; bad=1
  else
    # P3: the guard between the read and the sheet.
    between=${b#*"$get"}; between=${between%%"$open"*}
    has "$between" 'if (n > 0) runOnUiThread(() -> {' \
      || { echo "  FAIL  P3 the sheet does not open only for n > 0 on the UI thread" >&2; bad=1; }
    has "$between" 'if (!isFinishing() && !isDestroyed() && shownView == confirmView) {' \
      || { echo "  FAIL  P3 the sheet does not open only under !isFinishing() && !isDestroyed() && shownView == confirmView" >&2; bad=1; }
    # P2: the two slots.
    rest=${b#*"$open"}
    if ! has "$rest" "$sep" || ! has "$rest" '}, null);'; then
      echo "  FAIL  P2 the sheet's actions are not slot 0 ending in showAddCredits(), then slot 1, then a null onLink" >&2; bad=1
    else
      slot0=${rest%%"$sep"*}
      slot1=${rest#*"$sep"}; slot1=${slot1%%'}, null);'*}
      [ "$slot0" = " () -> { $ack; " ] \
        || { echo "  FAIL  P2 slot 0 does not send ClaimNoticeCopy.ackRequest(n) and then call showAddCredits():$slot0" >&2; bad=1; }
      [ "$slot1" = " () -> $ack " ] \
        || { echo "  FAIL  P2 slot 1 (Got it) is not only the ClaimNoticeCopy.ackRequest(n) send:$slot1" >&2; bad=1; }
    fi
  fi
  [ "$bad" -eq 0 ]
}

# check_all <ClaimNoticeCopy.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails,
# 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== ClaimNoticeCopy, ProfileActivity's claim notice"
check_all "$COPY" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases K1-K3 + pins P1-P3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# mut <label> <copy|pa> <the assertion that must convict it> <perl-expr> -> 0 convicted.
mut() {
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in copy) orig="$COPY" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    copy) out=$(check_all "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  case "$rc" in
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; rm -rf "$d"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) ;;
    *) echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
       rm -rf "$d"; return 1 ;;
  esac
  echo "  convicted $1 -- FAIL  $3"
  rm -rf "$d"
  return 0
}
fails=0
# NOTICE 0 already counts 0 (no notice), so the observable way to accept a non-positive n is a sign: NOTICE -1 -> -1.
mut "J1 count accepts a non-positive n (NOTICE -1)" copy K1 's/d\.matches\("\[0-9\]\+"\)/d.matches("[-+]?[0-9]+")/' || fails=$((fails+1))
mut "J2 count accepts any NOTICE prefix (NOTICES 2)" copy K1 's/r\.startsWith\("NOTICE "\)/r.startsWith("NOTICE")/; s/r\.substring\(7\)/r.substring(r.indexOf(\x27 \x27) + 1)/' || fails=$((fails+1))
mut "J3 TITLE_MANY for n == 1"                    copy K3 's/n == 1 \? TITLE_ONE : TITLE_MANY/TITLE_MANY/' || fails=$((fails+1))
mut "J4 ackRequest without its count line"        copy K2 's/"CLAIM-NOTICE-SHOWN\\n" \+ n \+ "\\n"/"CLAIM-NOTICE-SHOWN\\n"/' || fails=$((fails+1))
mut "J5 Got it styled GREEN_FILLED (two greens)"  copy K3 's/Button\(PopupSheet\.GOT_IT, PopupSheet\.Style\.OUTLINED\)/Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "J5b the second label OK (R_OK_CANCEL)"       copy K3 's/Button\(PopupSheet\.GOT_IT, PopupSheet\.Style\.OUTLINED\)/Button("OK", PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "J6 slot 1 null"                              pa   P2 's/(showAddCredits\(\); \},\n\s+)\(\) -> new Thread\(\(\) -> sendDaemon\(ClaimNoticeCopy\.ackRequest\(n\)\)\)\.start\(\)( \}, null\);)/${1}null$2/' || fails=$((fails+1))
mut "J7 the shownView check removed"              pa   P3 's/ && shownView == confirmView\) \{\n(\s+SheetDialog\.confirm\(this, ClaimNoticeCopy)/) {\n$1/' || fails=$((fails+1))
mut "J8 the read moved out of showConfirm"        pa   P1 's/(        setContentView\(sc\);\n)(.*?)(        if \(!claimNoticeAsked\) \{\n.*?\n        \}\n)(    \}\n)/${1}${2}        askClaimNotice();\n${4}\n    private void askClaimNotice() {\n${3}    }\n/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
