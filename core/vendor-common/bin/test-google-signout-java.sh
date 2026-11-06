#!/usr/bin/env bash
# test-google-signout-java.sh [--mutate] -- Profile > Preferences > "Sign out of Google" under javac (NWP-20261107-11).
#
# WHY THIS IS COMMITTED. #743 (decided 2026-10-20 dn-1025 #2, copy 2026-10-21 dn-1106 #2): roamd's acct_seal lets a
# zero-row #sys seal through only when every arriving account carries a mark, and nothing but the chooser's "Sign out of
# Google" row writes it. GoogleSignOut.java (pure) holds the hash, the marks-file rewrite and the decided wording; the
# cases below run it and compare the hash with `sha256sum` and with roamd's own acct_mark_hashes, so the two sides of the
# contract cannot drift. The PINS check the wiring cases cannot see: the mark is written BEFORE the account is removed,
# the account is removed only when that write succeeded, and a removal that fails takes its mark back out.
# Since NWP-20261113-31 Preferences holds one "Google accounts" row with the count, and the per-account rows are on
# their own screen (showGoogleAccounts); the pins check that split and the redraws after a sign-out.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-google-signout-java.sh            # the cases and the pins
#   bash test-google-signout-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
GSO="$root/core/chooser/src/com/nowhere/chooser/GoogleSignOut.java"
PA="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
MANIFEST="$root/core/chooser/AndroidManifest.xml"
ROAMD="$root/core/vendor-common/bin/nowhere_roamd.sh"
CASES="$root/core/chooser/tests/google-signout/GoogleSignOutCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its pins" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: this suite needs sha256sum" >&2; exit 2; }
for f in "$GSO" "$PA" "$MANIFEST" "$ROAMD" "$CASES"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# roamd's acct_mark_hashes and acct_mark_file, extracted by anchor, run under mksh (the device's shell) when present.
fn() { awk -v a="$2()" 'index($0, a " {")==1 { on=1 } on { print } on && /^}/ { exit }' "$1"; }
fn "$ROAMD" acct_mark_hashes > "$W/hashes.sh"
fn "$ROAMD" acct_mark_file > "$W/file.sh"
[ -s "$W/hashes.sh" ] && [ -s "$W/file.sh" ] || { echo "FAIL: roamd's acct_mark_hashes / acct_mark_file did not extract" >&2; exit 2; }
if command -v mksh >/dev/null 2>&1; then
  SH=mksh; PRELUDE=""
else
  echo "NOTE: no mksh here -- roamd's mark functions run under bash with a stand-in for mksh's print builtin (CI has mksh)"
  SH=bash
  PRELUDE='print() { local nl=1 a; while [ "$#" -gt 0 ]; do case "$1" in -r) shift ;; -rn) nl=0; shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
fi
ASCII='test.account@example.com'
UTF8=$(printf 't\303\251st.acc\303\266unt@example.com')
sum() { printf '%s' "nowhere-acct-mark-v1:$1" | sha256sum | cut -d' ' -f1; }
rhash() { "$SH" -c "$PRELUDE"$'\n'"$(cat "$W/hashes.sh")"$'\n''printf "%s\n" "$1" | acct_mark_hashes' x "$1"; }
RFILE=$("$SH" -c "$PRELUDE"$'\n'"$(cat "$W/file.sh")"$'\n''ACCT_MARK_ROOT=/r acct_mark_file 7')
A0=$(sum "$ASCII"); A1=$(rhash "$ASCII"); U0=$(sum "$UTF8"); U1=$(rhash "$UTF8")
[ "$RFILE" = "/r/7/com.nowhere.chooser/files/nowhere-acct-marks" ] || { echo "FAIL: roamd's acct_mark_file is [$RFILE]" >&2; exit 1; }
grep -qF '[ -s "$_mf.pending" ]' "$ROAMD" && grep -qF 'JOURNAL_FILE = "nowhere-acct-marks.pending"' core/chooser/src/com/nowhere/chooser/GoogleSignOut.java \
  || { echo "FAIL: roamd's acct_seal does not refuse on the chooser's journal (nowhere-acct-marks.pending)" >&2; exit 1; }

body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
# idx <text> <needle> -> byte offset of the first occurrence, -1 when absent
idx() { local pre="${1%%"$2"*}"; if [[ "$1" == *"$2"* ]]; then echo "${#pre}"; else echo -1; fi; }

# suite <GoogleSignOut.java> <ProfileActivity.java> <AndroidManifest.xml> -> 0 pass, 1 a case or pin failed, 3 compile
suite() {
  local g="$1" p="$2" m="$3" b i j n d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$g" "$d/src/com/nowhere/chooser/GoogleSignOut.java"; cp "$CASES" "$d/src/com/nowhere/chooser/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || { rm -rf "$d"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GoogleSignOutCases "$A0" "$A1" "$U0" "$U1" || { rm -rf "$d"; return 1; }
  rm -rf "$d"

  # P1: the sign-out writes the mark, removes the account only when that write succeeded, and removes it once
  b=$(body "$p" 'private void signOutGoogle(')
  i=$(idx "$b" 'GoogleSignOut.mark(acctMarksStore(GoogleSignOut.MARK_FILE)')
  j=$(idx "$b" '.removeAccount(')
  n=$(grep -o '\.removeAccount(' <<<"$b" | wc -l)
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ] && [ "$n" = 1 ]; } || { echo "  PIN P1 signOutGoogle does not write the mark before its one removeAccount call" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/if \(!recorded\) \{\s*GoogleSignOut\.release\(hash\);\s*googleSignOutFailed\("not recorded"\);\s*return;\s*\}/ ? 0 : 1)' || {
    echo "  PIN P1 a failed mark write does not stop before removeAccount" >&2; return 1; }
  [[ "$b" == *'boolean recorded = GoogleSignOut.mark('* ]] || { echo "  PIN P1 recorded is not the write's result" >&2; return 1; }
  [ "$(grep -o 'unmarkAndReport(hash)' <<<"$b" | wc -l)" = 2 ] || {
    echo "  PIN P1 the false-result and exception paths do not both take the mark back out" >&2; return 1; }
  [[ "$(body "$p" 'private void signOutGoogle(')" == *'i < 3 && !GoogleSignOut.settle(acctMarksStore(GoogleSignOut.JOURNAL_FILE), hash)'* ]] || {
    echo "  PIN P1 a landed removal does not settle its journal entry" >&2; return 1; }
  b=$(body "$p" 'private void confirmGoogleSignOut(')
  [[ "$b" == *'if (GoogleSignOut.claim(hash))'* ]] || { echo "  PIN P1 the sign-out does not claim its account first" >&2; return 1; }
  # P2: the mark file goes through a temp and a rename
  b=$(body "$p" 'private GoogleSignOut.Store acctMarksStore(')
  [[ "$b" == *'File.createTempFile(fileName'* && "$b" == *'tmp.renameTo(dst)'* ]] || {
    echo "  PIN P2 the store is not a temp file and a rename over MARK_FILE" >&2; return 1; }
  # P3: the failed removal takes its mark out BEFORE it reports
  b=$(body "$p" 'private void unmarkAndReport(')
  i=$(idx "$b" 'GoogleSignOut.unmark(acctMarksStore(GoogleSignOut.MARK_FILE)')
  j=$(idx "$b" 'googleSignOutFailed("not removed")')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || { echo "  PIN P3 unmarkAndReport does not unmark before it reports not removed" >&2; return 1; }
  b=$(body "$p" 'private void showPreferences(')
  [[ "$b" == *'sweepGoogleMarks();'* ]] || { echo "  PIN P3 showPreferences does not sweep a mark that could not be taken out" >&2; return 1; }
  b=$(body "$p" 'private void sweepGoogleMarks(')
  [[ "$b" == *'GoogleSignOut.sweep(acctMarksStore(GoogleSignOut.MARK_FILE), acctMarksStore(GoogleSignOut.JOURNAL_FILE)'* && "$b" == *'getAccountsByType(GoogleSignOut.ACCOUNT_TYPE)'* ]] || {
    echo "  PIN P3 the sweep does not read the phone's Google accounts" >&2; return 1; }
  [ "$(grep -c 'sweepGoogleMarks();' <<<"$(body "$p" 'private void probeSession(')")" = 1 ] || {
    echo "  PIN P3 the Profile screen does not sweep when it opens" >&2; return 1; }
  b=$(body "$p" 'private void googleSignOutFailed(')
  [[ "$b" == *'GoogleSignOut.failLine(why)'* ]] || { echo "  PIN P3 the failure does not show failLine" >&2; return 1; }
  # P4: Preferences holds ONE "Google accounts" row with the count (NWP-20261113-31); the per-account rows are on
  # showGoogleAccounts, from the offered Google accounts, each opening the decided dialog, Back to Preferences
  b=$(body "$p" 'private void addGoogleSignOutCard(')
  [[ "$b" == *'GoogleSignOut.offered(sessionType, offlineSession)'* && "$b" == *'getAccountsByType(GoogleSignOut.ACCOUNT_TYPE)'* \
     && "$b" == *'GoogleSignOut.GROUP_LABEL'* && "$b" == *'GoogleSignOut.groupSubtitle(accts.length)'* && "$b" == *'showGoogleAccounts()'* ]] || {
    echo "  PIN P4 Preferences does not draw one Google accounts row opening showGoogleAccounts" >&2; return 1; }
  [[ "$b" != *'GoogleSignOut.ROW_LABEL'* && "$b" != *'confirmGoogleSignOut('* ]] || {
    echo "  PIN P4 Preferences lists the per-account sign-out rows itself" >&2; return 1; }
  b=$(body "$p" 'private void showGoogleAccounts(')
  [[ "$b" == *'getAccountsByType(GoogleSignOut.ACCOUNT_TYPE)'* && "$b" == *'GoogleSignOut.ROW_LABEL'* \
     && "$b" == *'confirmGoogleSignOut(acct)'* && "$b" == *'finishMenuScreen(ll, () -> showPreferences());'* \
     && "$b" == *'sweepGoogleMarks();'* ]] || { echo "  PIN P4 showGoogleAccounts does not list the Google accounts with their sign-out" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/\A[^\n]*\{\s*if \(!GoogleSignOut\.offered\(sessionType, offlineSession\)\) \{\s*showPreferences\(\);\s*return;\s*\}.*?menuScreen\(/s ? 0 : 1)' || {
    echo "  PIN P4 showGoogleAccounts is not gated on offered() before it draws" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/if \(accts == null \|\| accts\.length == 0\) \{\s*showPreferences\(\);\s*return;\s*\}.*?menuScreen\(/s ? 0 : 1)' || {
    echo "  PIN P4 showGoogleAccounts draws with no account left instead of Preferences" >&2; return 1; }
  [[ "$(body "$p" 'private void signOutGoogle(')" == *'runOnUiThread(() -> showGoogleAccounts());'* ]] || {
    echo "  PIN P4 a landed sign-out does not redraw showGoogleAccounts" >&2; return 1; }
  b=$(body "$p" 'private void googleSignOutFailed(')
  [[ "$b" == *'showGoogleAccounts();'* && "$b" != *'showPreferences();'* ]] || {
    echo "  PIN P4 a failed sign-out does not redraw showGoogleAccounts" >&2; return 1; }
  b=$(body "$p" 'private void confirmGoogleSignOut(')
  [[ "$b" == *'.setTitle(GoogleSignOut.ROW_LABEL)'* && "$b" == *'.setMessage(GoogleSignOut.CONFIRM)'* \
     && "$b" == *'"Sign out"'* && "$b" == *'"Cancel"'* ]] || { echo "  PIN P4 the dialog does not use ROW_LABEL and CONFIRM" >&2; return 1; }
  b=$(body "$p" 'private void showPreferences(')
  [[ "$b" == *'addGoogleSignOutCard(ll);'* ]] || { echo "  PIN P4 showPreferences does not draw the card" >&2; return 1; }
  # P5: the file name is roamd's, the permission is declared once
  grep -q "^    static final String MARK_FILE = \"$(basename "$RFILE")\";" "$g" || { echo "  PIN P5 MARK_FILE is not roamd's file name" >&2; return 1; }
  [ "$(grep -c 'android.permission.GET_ACCOUNTS_PRIVILEGED"' "$m")" = 1 ] || { echo "  PIN P5 GET_ACCOUNTS_PRIVILEGED is not declared exactly once" >&2; return 1; }
  return 0
}

echo "== $GSO"
suite "$GSO" "$PA" "$MANIFEST" || { echo "FAILED"; exit 1; }
echo "all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin; a mutant that does not apply or compile proves nothing)"
fails=0
mut() { # mut <label> <gso|pa> <perl-expr>
  local d m g p rc; d=$(mktemp -d -p "$W"); g="$GSO"; p="$PA"
  if [ "$2" = gso ]; then m="$d/GoogleSignOut.java"; perl -0pe "$3" "$GSO" > "$m" || { echo "  ERROR     $1 -- perl failed"; return 1; }
    cmp -s "$GSO" "$m" && { echo "  INERT     $1"; return 1; }; g="$m"
  else m="$d/ProfileActivity.java"; perl -0pe "$3" "$PA" > "$m" || { echo "  ERROR     $1 -- perl failed"; return 1; }
    cmp -s "$PA" "$m" && { echo "  INERT     $1"; return 1; }; p="$m"
  fi
  suite "$g" "$p" "$MANIFEST" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 (rc=$rc)"; return 1 ;;
  esac
}
mut "G1 the hash without the prefix"          gso 's/\(MARK_PREFIX \+ name\)/name/' || fails=$((fails+1))
mut "G2 upper-case hex"                       gso 's/Character\.forDigit\(\(b >> 4\) & 0xF, 16\)\)\.append\(Character\.forDigit\(b & 0xF, 16\)\)/Character.toUpperCase(Character.forDigit((b >> 4) \& 0xF, 16))).append(Character.toUpperCase(Character.forDigit(b \& 0xF, 16)))/' || fails=$((fails+1))
mut "G3 removeAccount before the mark write"  pa 's/(private void signOutGoogle\(final android\.accounts\.Account acct, final String hash\) \{\n)/$1        android.accounts.AccountManager.get(this).removeAccount(acct, this, null, null);\n/' || fails=$((fails+1))
mut "G4 a duplicate appended"                 gso 's/if \(!hs\.contains\(hash\)\) hs\.add\(hash\);/hs.add(hash);/' || fails=$((fails+1))
mut "G5 offered to a LOCAL session"           gso 's/return !offline && "STORED"\.equals\(sessionType\);/return !offline;/' || fails=$((fails+1))
mut "G6 the confirmation text changed"        gso 's/Signing out in Android Settings does not stick\./Signing out in Android Settings sticks./' || fails=$((fails+1))
mut "G7 removeAccount called when the write failed" pa 's/if \(!recorded\) \{/if (false) {/' || fails=$((fails+1))
mut "G8 the mark left in place when the removal fails" pa 's/GoogleSignOut\.unmark\(acctMarksStore\(GoogleSignOut\.MARK_FILE\), acctMarksStore\(GoogleSignOut\.JOURNAL_FILE\), hash\)/true/' || fails=$((fails+1))
mut "G9 the mark read-modify-write unlocked" gso 's/(static boolean mark\(Store marks, Store journal, String hash\) \{\n\s*)synchronized \(LOCK\)/$1synchronized (new Object())/' || fails=$((fails+1))
mut "G10 a failed rollback write keeps the mark" gso 's/(\n\s*try \{\n\s*)marks\.delete\(\);(\n\s*out = true;)/$1if (hash == null) marks.delete();$2/' || fails=$((fails+1))
mut "G11 the claim lets a second sign-out in" gso 's/return PENDING\.add\(hash\);/PENDING.add(hash); return true;/' || fails=$((fails+1))
mut "G12 the rollback unlocked" gso 's/(static boolean unmark\(Store marks, Store journal, String hash\) \{\n\s*)synchronized \(LOCK\)/$1synchronized (new Object())/' || fails=$((fails+1))
mut "G13 the sweep leaves a mark beside a present account" gso 's/open\.contains\(h\) \|\| here\.contains\(h\)\) stale = true;/open.contains(h)) stale = true;/' || fails=$((fails+1))
mut "G14 the sweep removes a claimed sign-out's mark" gso 's/if \(PENDING\.contains\(h\)\) \{ keep\.add\(h\); continue; \}//' || fails=$((fails+1))
mut "G15 the sweep removes a mark whose account is gone and journal settled" gso 's/open\.contains\(h\) \|\| here\.contains\(h\)\) stale = true;/open.contains(h) || here.contains(h) || true) stale = true;/' || fails=$((fails+1))
mut "G16 the Profile screen does not sweep" pa 's/(updateStatus = OtaUpdate\.parse\(r\.otaLines\);\n\s*)sweepGoogleMarks\(\);/$1/' || fails=$((fails+1))
mut "G17 an open journal entry does not withdraw its mark when the account is gone" gso 's/open\.contains\(h\) \|\| here/here/' || fails=$((fails+1))
mut "G18 the journal is written after the mark, or not at all" gso 's/journal\.write\(withMark\(journal\.read\(\), hash\)\);//' || fails=$((fails+1))
mut "G19 a failed rollback drops its journal entry" gso 's/if \(out\) dropEntry\(journal, hash\);/dropEntry(journal, hash);/' || fails=$((fails+1))
mut "G20 an unreadable journal is trusted as empty" gso 's/journalLost = true;/journalLost = false;/' || fails=$((fails+1))
mut "G21 a landed removal leaves its journal entry" pa 's/for \(int i = 0; i < 3 && !GoogleSignOut\.settle/for (int i = 0; i < 0 \&\& !GoogleSignOut.settle/' || fails=$((fails+1))
mut "G22 groupSubtitle says accounts for 1"   gso 's/n == 1 \? "1 account"/n == 1 ? "1 accounts"/' || fails=$((fails+1))
mut "G23 the per-account rows back on Preferences" pa 's/(\Qgoogle'"Card(ll).addView(googleCardRow(GoogleSignOut.GROUP_LABEL, GoogleSignOut.groupSubtitle(accts.length), () -> showGoogleAccounts()));"'\E)/$1\n        for (android.accounts.Account a : accts) ll.addView(googleCardRow(GoogleSignOut.ROW_LABEL, a.name, () -> confirmGoogleSignOut(a)));/' || fails=$((fails+1))
mut "G24 the screen's rows do not sign out"  pa 's/\(\) -> confirmGoogleSignOut\(acct\)\)\);/() -> {}));/' || fails=$((fails+1))
mut "G25 the screen without the offered gate" pa 's/(private void showGoogleAccounts\(\) \{\n)\s*if \(!GoogleSignOut\.offered\(sessionType, offlineSession\)\) \{\n\s*showPreferences\(\);\n\s*return;\n\s*\}\n/$1/' || fails=$((fails+1))
mut "G26 a failed sign-out redraws only Preferences" pa 's/(GoogleSignOut\.failLine\(why\), android\.widget\.Toast\.LENGTH_LONG\)\.show\(\);\n\s*)showGoogleAccounts\(\);/$1showPreferences();/' || fails=$((fails+1))
mut "G27 a landed sign-out redraws only Preferences" pa 's/runOnUiThread\(\(\) -> showGoogleAccounts\(\)\);/runOnUiThread(() -> showPreferences());/' || fails=$((fails+1))
mut "G28 the screen draws with no account left" pa 's/\n\s*if \(accts == null \|\| accts\.length == 0\) \{\n\s*showPreferences\(\);\n\s*return;\n\s*\}(\n\s*sweepGoogleMarks\(\);\n\s*LinearLayout ll = menuScreen\(GoogleSignOut\.GROUP_LABEL)/$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
