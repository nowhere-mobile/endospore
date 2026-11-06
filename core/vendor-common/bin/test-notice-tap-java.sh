#!/usr/bin/env bash
# test-notice-tap-java.sh [--mutate] -- a tap on the gate's multi-notice summary opens a per-notice popup (NWP-20261105-06).
#
# WHY THIS IS COMMITTED. Q064 (docs/product-decisions.md, 2026-10-20): several notices make the banner tappable to a popup
# of each notice's own line, and the unassigned line's entry carries "Open owner inbox" -- the 2026-09-01 (e) route, which
# goes to owner VERIFY and never past it, and only with an owner secret set. A single notice, whatever its count, keeps the
# older rule. NoticeTap (pure, java.lang / java.util) holds the decision and is compiled here with its cases; SOURCE
# checks over ChooserActivity (P1-P10) pin the wiring a javac run cannot reach: the banner asks NoticeTap, the verify
# route lands on verify and is the banner's only way there, the popup builds the inbox view only inside the guard and
# shows field 4 only, telNotices marks the unassigned line's notice, POPUP opens the popup and NONE alone is
# untappable, every refresh first closes the popup showNoticePopup keeps in the noticePopup field, a tap while
# that popup is up opens no second one, and onDestroy closes it first, while its window is still attached.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-notice-tap-java.sh            # the cases and the source checks
#   bash test-notice-tap-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CASES="$root/core/chooser/tests/notice-tap/NoticeTapCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# body <file> <signature> -> from the line holding the signature to the first line that is exactly "    }".
body() { awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# count <text> <fixed string> -> the number of non-comment lines holding it.
count() { printf '%s\n' "$1" | S="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }

# source_checks <dir with ChooserActivity.java> -> 0 when every check holds.
source_checks() {
  local f="$1/ChooserActivity.java" bad=0 banner popup tn sum guard destroy
  banner=$(body "$f" 'private void refreshNoticeBanner() {')
  popup=$(body "$f" 'private void showNoticePopup() {')
  destroy=$(body "$f" 'protected void onDestroy() {')
  tn=$(body "$f" 'private java.util.List<String[]> telNotices(java.util.Set<String> skip) {')
  sum=$(body "$f" 'private String telNoticeSummary(java.util.Set<String> skip) {')
  guard=$(printf '%s\n' "$popup" | awk '/if \(NoticeTap\.inboxButton\(notices\.get\(i\), owner\)\) \{/ { on = 1 } on { print } on && /^            }$/ { exit }')
  [ -n "$banner" ] || { echo "  FAIL  refreshNoticeBanner not found" >&2; return 1; }
  [ -n "$popup" ]  || { echo "  FAIL  showNoticePopup not found" >&2; return 1; }
  [ -n "$tn" ]     || { echo "  FAIL  telNotices not found" >&2; return 1; }
  [ -n "$sum" ]    || { echo "  FAIL  telNoticeSummary not found" >&2; return 1; }
  [ -n "$destroy" ] || { echo "  FAIL  onDestroy not found" >&2; return 1; }
  [ -n "$guard" ]  || { echo "  FAIL  P3: the popup's inboxButton guard not found" >&2; bad=1; }

  [ "$(count "$banner" 'NoticeTap.action(notices, ownerSecretSet())')" -eq 1 ] \
    || { echo "  FAIL  P1: refreshNoticeBanner does not ask NoticeTap.action(notices, ownerSecretSet())" >&2; bad=1; }
  [ "$(count "$banner" 'if (NoticeTap.VERIFY.equals(tap)) noticeBanner.setOnClickListener(v -> setContentView(buildOwnerVerifyScreen(StoreGate.DEST_INBOX)));')" -eq 1 ] \
    || { echo "  FAIL  P2: the VERIFY branch is not setContentView(buildOwnerVerifyScreen(StoreGate.DEST_INBOX))" >&2; bad=1; }
  [ "$(count "$banner" 'buildOwnerVerifyScreen(')" -eq 1 ] \
    || { echo "  FAIL  P2: refreshNoticeBanner reaches buildOwnerVerifyScreen( other than on the VERIFY line" >&2; bad=1; }
  [ "$(count "$banner" 'DEST_MENU')" -eq 0 ] || { echo "  FAIL  P2: the banner routes to DEST_MENU" >&2; bad=1; }
  [ "$(count "$guard" '"Open owner inbox"')" -eq 1 ] && [ "$(count "$popup" '"Open owner inbox"')" -eq 1 ] \
    || { echo "  FAIL  P3: \"Open owner inbox\" is not created exactly once, inside the inboxButton guard" >&2; bad=1; }
  [ "$(count "$guard" 'buildOwnerVerifyScreen(StoreGate.DEST_INBOX)')" -eq 1 ] && [ "$(count "$popup" 'buildOwnerVerifyScreen(')" -eq 1 ] \
    || { echo "  FAIL  P3: the popup does not reach owner verify exactly once, inside the guard" >&2; bad=1; }
  [ "$(count "$popup" 'buildOwnerInboxScreen(')$(count "$popup" 'buildOwnerMenu(')$(count "$popup" 'buildOwnerEnrollScreen(')" = 000 ] \
    || { echo "  FAIL  P3: the popup reaches the inbox, menu or enrolment without the verify" >&2; bad=1; }
  [ "$(count "$sum" 'java.util.List<String[]> n = telNotices(skip);')" -eq 1 ] \
    && [ "$(count "$sum" 'return n == null ? null : summarize(n);')" -eq 1 ] \
    || { echo "  FAIL  P4: telNoticeSummary is not summarize of telNotices" >&2; bad=1; }
  [ "$(count "$popup" 'NoticeTap.lines(notices)')" -eq 1 ] \
    || { echo "  FAIL  P5: the popup does not take its text from NoticeTap.lines(notices)" >&2; bad=1; }
  local w
  for w in extras getActiveNotifications getCharSequence EXTRA_ 'getString('; do
    [ "$(count "$popup" "$w")" -eq 0 ] || { echo "  FAIL  P5: the popup reads $w itself" >&2; bad=1; }
  done
  [ "$(count "$tn" 'boolean unbound = "unbound".equals(ex.getString("nowhere_line", ""))')" -eq 1 ] \
    && [ "$(count "$tn" '|| title.toString().endsWith(SmsDeliverReceiver.UNBOUND_LINE);')" -eq 1 ] \
    && [ "$(count "$tn" 'String.valueOf(unbound)});')" -eq 1 ] \
    || { echo "  FAIL  P6: telNotices does not set the sixth field from the nowhere_line extra or the label" >&2; bad=1; }
  [ "$(count "$banner" 'else if (NoticeTap.POPUP.equals(tap)) noticeBanner.setOnClickListener(v -> showNoticePopup());')" -eq 1 ] \
    && [ "$(count "$banner" 'noticeBanner.setClickable(!NoticeTap.NONE.equals(tap));')" -eq 1 ] \
    || { echo "  FAIL  P7: the POPUP branch does not open showNoticePopup, or NONE is not the one untappable answer" >&2; bad=1; }
  [ "$(printf '%s\n' "$banner" | awk 'NR > 1 && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print; exit }')" \
      = '        if (noticePopup != null) { noticePopup.dismiss(); noticePopup = null; }' ] \
    && [ "$(printf '%s\n' "$popup" | grep -cxF '        noticePopup = new android.app.AlertDialog.Builder(this)')" -eq 1 ] \
    || { echo "  FAIL  P8: refreshNoticeBanner does not first dismiss the popup showNoticePopup keeps in noticePopup" >&2; bad=1; }
  [ "$(printf '%s\n' "$popup" | awk 'NR > 1 && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print; exit }')" \
      = '        if (noticePopup != null && noticePopup.isShowing()) return;' ] \
    || { echo "  FAIL  P9: showNoticePopup does not first refuse a second popup over a showing one" >&2; bad=1; }
  [ "$(printf '%s\n' "$destroy" | awk 'NR > 1 && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print; exit }')" \
      = '        if (noticePopup != null) { noticePopup.dismiss(); noticePopup = null; }' ] \
    || { echo "  FAIL  P10: onDestroy does not first dismiss the popup and forget it, before super.onDestroy()" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# suite <dir holding NoticeTap.java and ChooserActivity.java> -> 0 pass, 1 a case or check failed, 3 did not compile.
suite() {
  local dir="$1" d out rc
  [ -f "$dir/NoticeTap.java" ] || { echo "  FAIL  NoticeTap.java does not exist (the tap decision is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$dir/NoticeTap.java" "$d/src/com/nowhere/chooser/NoticeTap.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/NoticeTapCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.NoticeTapCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  [ -f "$dir/ChooserActivity.java" ] || { echo "  FAIL  ChooserActivity.java missing" >&2; return 1; }
  source_checks "$dir" || return 1
  return 0
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that is inert or does not compile proves nothing)"
# mutate <label> <file name> <sed script>
mutate() {
  local label="$1" file="$2" script="$3" d rc
  d=$(mktemp -d -p "$W") || return 1
  cp "$SRC"/*.java "$d/"
  sed -i "$script" "$d/$file"
  if cmp -s "$SRC/$file" "$d/$file"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$d" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  convicted $label"; return 0 ;;
    0) echo "  SURVIVED  $label"; return 1 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
N=NoticeTap.java; C=ChooserActivity.java
mutate "M1 a multi-notice list answers NONE" $N 's/^        return POPUP;$/        return NONE;/' || fails=$((fails+1))
mutate "M2 a single notice answers POPUP" $N 's/if (notices.size() == 1) return inboxButton(notices.get(0), ownerSecretSet) ? VERIFY : NONE;/if (notices.size() == 1) return POPUP;/' || fails=$((fails+1))
mutate "M3 inboxButton ignores ownerSecretSet" $N 's/return ownerSecretSet \&\& notice != null/return notice != null/' || fails=$((fails+1))
mutate "M4 the sixth field is always false" $C 's/^                        String.valueOf(unbound)});$/                        "false"});/' || fails=$((fails+1))
mutate "M5 VERIFY routes to DEST_MENU" $C '/private void refreshNoticeBanner() {/,/^    }$/s/buildOwnerVerifyScreen(StoreGate.DEST_INBOX)/buildOwnerVerifyScreen(StoreGate.DEST_MENU)/' || fails=$((fails+1))
mutate "M6 a single notice with a count above 1 answers POPUP" $N 's/if (notices.size() == 1) return/if (notices.size() == 1 \&\& "1".equals(notices.get(0)[2])) return/' || fails=$((fails+1))
mutate "M7 the multi-notice tap does nothing" $C 's/v -> showNoticePopup()/null/' || fails=$((fails+1))
mutate "M8 the NONE branch reaches owner verify" $C 's/^        else noticeBanner.setOnClickListener(null);$/        else noticeBanner.setOnClickListener(v -> setContentView(buildOwnerVerifyScreen(StoreGate.DEST_INBOX)));/' || fails=$((fails+1))
mutate "M9 a refresh leaves the popup open" $C '/private void refreshNoticeBanner() {/,/^    }$/{/^        if (noticePopup != null) { noticePopup.dismiss(); noticePopup = null; }$/d;}' || fails=$((fails+1))
mutate "M10 a NONE banner stays tappable" $C 's/noticeBanner.setClickable(!NoticeTap.NONE.equals(tap));/noticeBanner.setClickable(true);/' || fails=$((fails+1))
mutate "M11 the popup is not kept where a refresh can close it" $C 's/^        noticePopup = new android.app.AlertDialog.Builder(this)$/        new android.app.AlertDialog.Builder(this)/' || fails=$((fails+1))
mutate "M12 a second tap opens a second popup over the first" $C '/^        if (noticePopup != null && noticePopup.isShowing()) return;$/d' || fails=$((fails+1))
mutate "M13 the popup goes to a local that shadows the field" $C 's/^        noticePopup = new android.app.AlertDialog.Builder(this)$/        final android.app.AlertDialog noticePopup = new android.app.AlertDialog.Builder(this)/' || fails=$((fails+1))
mutate "M14 onDestroy leaves an open popup to leak" $C '/protected void onDestroy() {/,/^    }$/{/^        if (noticePopup != null) { noticePopup.dismiss(); noticePopup = null; }$/d;}' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
