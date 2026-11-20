#!/usr/bin/env bash
# test-scan-net-hold-java.sh [--mutate] -- the Gallery's landed-media rescan waits for an unmetered network when the
# profile asks, run under javac (NWP-20261208-19).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-16, "DECIDED: the Gallery's sign-in scan runs on any network
# by default, and becomes a setting". A per-profile switch on Offline media (ScanNetHold.FILE in the session's chooser
# files dir, default off = any network) holds the gate's landed-media rescan (the NWP-20261114-34 watcher ->
# requestMediaRescan -> CredentialService rescanmedia) on a metered network, and the gate re-asks once its network is
# unmetered. roamd's sign-in rescan (nowhere_roamd.sh rescan_media) indexes local files only and is never held. Each
# rule fails quietly: a held roamd start leaves the restored photos out of the Gallery, a hold that starts the scan
# anyway spends mobile data, a re-ask for the wrong session or one that never comes leaves photos unlisted.
#
# WHAT IS PINNED.
#   * Cases (ScanNetHold.java compiled unchanged, the package line stripped, against
#     core/chooser/tests/scan-net-hold/ScanNetHoldCases.java): O1-O6 on(), D1-D8 the whole decide table, T1-T5
#     retryNow, W1 LABEL and SUB not empty.
#   * W1 (source, the raw ScanNetHold.java): the line directly above LABEL and SUB is the DRAFT marker.
#   * Pins on the comment-stripped sources (a method that does not extract is exit 2, never a pass):
#     P1 requestMediaRescan puts EXTRA_LANDED and marks sRescanMeteredUid under !unmeteredCtx(app);
#     P2 the watcher calls retryHeldRescan(app, uid) after `landedSeen = landedNow;`, its gate branch clears
#        sRescanMeteredUid, and retryHeldRescan asks through ScanNetHold.retryNow with EXTRA_RETRY;
#     P3 CredentialService's rescanmedia branch calls ScanNetHold.decide BEFORE `new Thread(`, and HOLD and SKIP
#        each finishUnit() and return START_NOT_STICKY;
#     P4 nowhere_roamd.sh rescan_media's am line carries neither extra (roamd's start stays RUN);
#     P5 showOfflineMedia adds the row after the mobile-data row with ScanNetHold.LABEL / SUB, read/writeScanUnmetered.
# ChooserActivity, CredentialService and ProfileActivity themselves are compiled by the merger's full javac check /
# `m NowhereChooser`, not here.
#
# Exit: 0 pass, 1 a case or a pin failed (the only code that convicts a mutant), 2 the suite could not run (no javac,
# a missing file, a member that did not extract), 3 a compile failure.
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-scan-net-hold-java.sh            # the cases and the pins
#   bash test-scan-net-hold-java.sh --mutate   # ... plus N1-N11, broken copies that must each be CONVICTED
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="$HERE/src/com/nowhere/chooser"
SNH="$DIR/ScanNetHold.java"
CA="$DIR/ChooserActivity.java"
CS="$DIR/CredentialService.java"
PA="$DIR/ProfileActivity.java"
ROAMD="$ROOT/core/vendor-common/bin/nowhere_roamd.sh"
CASES="$HERE/tests/scan-net-hold/ScanNetHoldCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version >/dev/null 2>&1 || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: no perl -- the pins need it" >&2; exit 2; }
for f in "$SNH" "$CA" "$CS" "$PA" "$ROAMD" "$CASES"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# strip_java <file> -> the text with // and /* */ comments blanked, string and char literals kept.
strip_java() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}
# extract <file> <literal first line> <closing line regex> -> the lines from the first one holding the literal to the
# first closing line after it; empty when the literal is not found.
extract() {
  awk -v s="$2" -v e="$3" 'index($0, s) { on = 1 } on { print } on && $0 ~ e { exit }' "$1"
}
# pin <id> <what> <text file> <perl regex>: fails (prints, returns 1) when the regex does not match.
pin() {
  if RE="$4" perl -0ne 'BEGIN { $r = $ENV{RE} } exit(/$r/s ? 0 : 1)' "$3"; then echo "  ok    $1"; return 0; fi
  echo "  FAIL  $1 $2" >&2; return 1
}
# nopin <id> <what> <text file> <perl regex>: fails when the regex DOES match.
nopin() {
  if RE="$4" perl -0ne 'BEGIN { $r = $ENV{RE} } exit(/$r/s ? 0 : 1)' "$3"; then echo "  FAIL  $1 $2" >&2; return 1; fi
  echo "  ok    $1"; return 0
}

# suite <ScanNetHold.java> <ChooserActivity.java> <CredentialService.java> <ProfileActivity.java> <nowhere_roamd.sh>
suite() {
  local snh="$1" ca="$2" cs="$3" pa="$4" roamd="$5" d bad=0 t
  d=$(mktemp -d -p "$W") || return 2

  # The cases, on ScanNetHold compiled unchanged.
  mkdir -p "$d/src" "$d/cls" || return 2
  sed '/^package /d' "$snh" > "$d/src/ScanNetHold.java" || return 2
  cp "$CASES" "$d/src/ScanNetHoldCases.java" || return 2
  "$JAVAC" -d "$d/cls" "$d/src/ScanNetHold.java" "$d/src/ScanNetHoldCases.java" >&2 || { echo "  COMPILE FAILED" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/cls" ScanNetHoldCases || bad=1

  # W1: each draft string carries the marker on the line directly above it.
  pin "W1 LABEL" "is not directly below the DRAFT marker" "$snh" \
    '\n[ \t]*// DRAFT \(NWP-20261208-19\): Chester'"'"'s mockup decides\n[ \t]*static final String LABEL = "[^"]+";' || bad=1
  pin "W1 SUB" "is not directly below the DRAFT marker" "$snh" \
    '\n[ \t]*// DRAFT \(NWP-20261208-19\): Chester'"'"'s mockup decides\n[ \t]*static final String SUB = "[^"]+";' || bad=1

  # P1, P2: ChooserActivity.
  strip_java "$ca" > "$d/ca" || return 2
  extract "$d/ca" 'private static void requestMediaRescan(Context app, int uid, String count) {' '^    }$' > "$d/rmr"
  extract "$d/ca" 'private static void retryHeldRescan(Context app, int uid) {' '^    }$' > "$d/rhr"
  extract "$d/ca" 'private void startSyncStatusWatcher() {' '^    }$' > "$d/watch"
  for t in rmr rhr watch; do
    [ -s "$d/$t" ] || { echo "EXTRACTION FAILED -- $t not found in $ca" >&2; return 2; }
  done
  pin P1 "requestMediaRescan does not put EXTRA_LANDED before rescanmedia" "$d/rmr" \
    'new android\.content\.Intent\(app, CredentialService\.class\)\.putExtra\(ScanNetHold\.EXTRA_LANDED, true\)\.putExtra\("rescanmedia", true\),' || bad=1
  pin P1 "requestMediaRescan does not mark sRescanMeteredUid under !unmeteredCtx(app) before the start" "$d/rmr" \
    'if \(!unmeteredCtx\(app\)\) sRescanMeteredUid\.set\(uid\);.*app\.startServiceAsUser\(' || bad=1
  pin P2 "the watcher does not call retryHeldRescan(app, uid) after landedSeen = landedNow" "$d/watch" \
    'landedSeen = landedNow;.*\bretryHeldRescan\(app, uid\);' || bad=1
  pin P2 "the watcher's gate branch does not clear sRescanMeteredUid" "$d/watch" \
    'if \(uid < 0\) \{(?:(?!continue;).)*\bsRescanMeteredUid\.set\(-1\);(?:(?!continue;).)*continue;' || bad=1
  pin P2 "retryHeldRescan does not ask ScanNetHold.retryNow, clear the mark, then re-ask with EXTRA_RETRY" "$d/rhr" \
    'if \(!ScanNetHold\.retryNow\(sRescanMeteredUid\.get\(\), uid, unmeteredCtx\(app\)\)\) return;\s*sRescanMeteredUid\.set\(-1\);.*app\.startServiceAsUser\(new android\.content\.Intent\(app, CredentialService\.class\)\s*\.putExtra\(ScanNetHold\.EXTRA_LANDED, true\)\.putExtra\(ScanNetHold\.EXTRA_RETRY, true\)\s*\.putExtra\("rescanmedia", true\), android\.os\.UserHandle\.of\(uid\)\);' || bad=1

  # P3: CredentialService's rescanmedia branch.
  strip_java "$cs" > "$d/cs" || return 2
  extract "$d/cs" 'if (intent != null && intent.getBooleanExtra("rescanmedia", false)) {' '^        }$' > "$d/br"
  [ -s "$d/br" ] || { echo "EXTRACTION FAILED -- the rescanmedia branch not found in $cs" >&2; return 2; }
  perl -0ne 'print $1 if /\A(.*?)new Thread\(/s' "$d/br" > "$d/pre"
  [ -s "$d/pre" ] || { echo "  FAIL  P3 the rescanmedia branch starts no thread" >&2; bad=1; }
  pin P3 "the branch does not read ScanNetHold.FILE through SettingsText.read before the thread" "$d/pre" \
    'String text = SettingsText\.read\(new java\.io\.File\(getFilesDir\(\), ScanNetHold\.FILE\)\);' || bad=1
  pin P3 "the branch does not call ScanNetHold.decide before the thread" "$d/pre" \
    'int d = ScanNetHold\.decide\(intent\.getBooleanExtra\(ScanNetHold\.EXTRA_LANDED, false\),\s*intent\.getBooleanExtra\(ScanNetHold\.EXTRA_RETRY, false\), ScanNetHold\.on\(text\),\s*ChooserActivity\.unmeteredCtx\(this\)\);' || bad=1
  pin P3 "HOLD does not finishUnit() and return before the thread" "$d/pre" \
    'if \(d == ScanNetHold\.HOLD\) \{[^{}]*\bfinishUnit\(\);\s*return START_NOT_STICKY;\s*\}' || bad=1
  pin P3 "SKIP does not finishUnit() and return before the thread" "$d/pre" \
    'if \(d == ScanNetHold\.SKIP\) \{[^{}]*\bfinishUnit\(\);\s*return START_NOT_STICKY;\s*\}' || bad=1

  # P4: roamd's sign-in start carries neither extra.
  extract "$roamd" 'rescan_media() {' '^}$' > "$d/rm"
  [ -s "$d/rm" ] || { echo "EXTRACTION FAILED -- rescan_media not found in $roamd" >&2; return 2; }
  grep -E '^[[:space:]]*am startservice ' "$d/rm" > "$d/am" || true
  pin P4 "rescan_media no longer starts CredentialService rescanmedia (control)" "$d/am" \
    'am startservice --user "\$1" -n com\.nowhere\.chooser/\.CredentialService .*--ez rescanmedia true' || bad=1
  nopin P4 "rescan_media's am line carries a landing or retry extra (roamd's start would be held)" "$d/am" \
    'rescanlanded|rescanretry' || bad=1

  # P5: the Offline media row.
  strip_java "$pa" > "$d/pa" || return 2
  extract "$d/pa" 'private void showOfflineMedia() {' '^    }$' > "$d/som"
  extract "$d/pa" 'private boolean readScanUnmetered() {' '^    }$' > "$d/rsu"
  extract "$d/pa" 'private boolean writeScanUnmetered(boolean on) {' '^    }$' > "$d/wsu"
  for t in som rsu wsu; do
    [ -s "$d/$t" ] || { echo "EXTRACTION FAILED -- $t not found in $pa" >&2; return 2; }
  done
  pin P5 "showOfflineMedia does not add the row after the mobile-data row with ScanNetHold.LABEL and SUB" "$d/som" \
    'll\.addView\(mrow, new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);.*\.setText\(ScanNetHold\.LABEL\);.*\.setText\(ScanNetHold\.SUB\);' || bad=1
  pin P5 "the row's switch is not set from readScanUnmetered()" "$d/som" '\.setChecked\(readScanUnmetered\(\)\);' || bad=1
  pin P5 "a failed writeScanUnmetered does not show NOT_SAVED and redraw" "$d/som" \
    'if \(!writeScanUnmetered\(on\)\) \{\s*android\.widget\.Toast\.makeText\(this, SettingsSaveCopy\.NOT_SAVED, android\.widget\.Toast\.LENGTH_LONG\)\.show\(\);\s*showOfflineMedia\(\);' || bad=1
  pin P5 "readScanUnmetered does not read ScanNetHold.FILE through ScanNetHold.on" "$d/rsu" \
    'return ScanNetHold\.on\(SettingsText\.read\(new java\.io\.File\(getFilesDir\(\), ScanNetHold\.FILE\)\)\);' || bad=1
  pin P5 "writeScanUnmetered off does not delete ScanNetHold.FILE" "$d/wsu" \
    'new java\.io\.File\(getFilesDir\(\), ScanNetHold\.FILE\);\s*if \(!on\) \{ f\.delete\(\); return !f\.exists\(\); \}' || bad=1

  [ "$bad" -eq 0 ] || return 1
  return 0
}

echo "== cases and pins (NWP-20261208-19)"
suite "$SNH" "$CA" "$CS" "$PA" "$ROAMD"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit "$rc"; }
echo "== all cases and pins pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED, rc 1)"
# mut <label> <snh|ca|cs|roamd> <perl-expr>: mutate one copy, run the suite, expect rc 1.
mut() {
  local label="$1" kind="$2" expr="$3" d orig c rc s="$SNH" a="$CA" v="$CS" r="$ROAMD"
  case "$kind" in
    snh) orig="$SNH" ;; ca) orig="$CA" ;; cs) orig="$CS" ;; roamd) orig="$ROAMD" ;;
    *) echo "  ERROR     $label -- unknown kind $kind"; return 1 ;;
  esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c" || return 1
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$kind" in snh) s="$c" ;; ca) a="$c" ;; cs) v="$c" ;; roamd) r="$c" ;; esac
  suite "$s" "$a" "$v" "$PA" "$r" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  convicted $label"; return 0 ;;
    0) echo "  SURVIVED  $label"; return 1 ;;
    *) echo "  BROKEN    $label -- rc=$rc, not a conviction"; return 1 ;;
  esac
}
fails=0
mut "N1 on() accepts any non-empty text (O3, O6)" snh \
  's/fileText\.trim\(\)\.equals\("1"\)/!fileText.trim().isEmpty()/' || fails=$((fails+1))
mut "N2 decide holds an unlanded start (D1)" snh \
  's/if \(!landed\) return RUN;/if (!landed) return on \&\& !unmetered ? HOLD : RUN;/' || fails=$((fails+1))
mut "N3 decide ignores unmetered on the first ask (D5)" snh \
  's/if \(!retry\) return on && !unmetered \? HOLD : RUN;/if (!retry) return on ? HOLD : RUN;/' || fails=$((fails+1))
mut "N4 SKIP on a re-ask becomes RUN (D7)" snh 's/return SKIP;/return RUN;/' || fails=$((fails+1))
mut "N5 retryNow drops the uid match (T3, T4)" snh 's/ && askedMeteredUid == uid//' || fails=$((fails+1))
mut "N6 EXTRA_LANDED removed from requestMediaRescan (P1)" ca \
  's/\.putExtra\(ScanNetHold\.EXTRA_LANDED, true\)\.putExtra\("rescanmedia", true\),/.putExtra("rescanmedia", true),/' \
  || fails=$((fails+1))
mut "N7 the watcher's retryHeldRescan call deleted (P2)" ca 's/\n[ \t]*retryHeldRescan\(app, uid\);[^\n]*//' || fails=$((fails+1))
mut "N8 the gate branch's sRescanMeteredUid reset deleted (P2)" ca \
  's/(landedUid = -1;[^\n]*)\n[ \t]*sRescanMeteredUid\.set\(-1\);[^\n]*/$1/' || fails=$((fails+1))
mut "N9 decide moved inside the thread (P3)" cs \
  's/(\n[ \t]*int d = ScanNetHold\.decide\(.*?\);)(.*?new Thread\(\(\) -> \{)/$2$1/s' || fails=$((fails+1))
mut "N10 HOLD falls through to the scan (P3)" cs \
  's/(if \(d == ScanNetHold\.HOLD\) \{\n[^\n]*\n)[ \t]*finishUnit\(\);\n[ \t]*return START_NOT_STICKY;\n/$1/' \
  || fails=$((fails+1))
mut "N11 roamd's am line gains --ez rescanlanded true (P4)" roamd \
  's/(\nrescan_media\(\) \{\n[^\n]*?)--ez rescanmedia true/$1--ez rescanlanded true --ez rescanmedia true/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
