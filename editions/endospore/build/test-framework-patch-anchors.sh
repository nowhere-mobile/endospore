#!/usr/bin/env bash
# test-framework-patch-anchors.sh [--mutate] -- NWP-20261015-29.
#
# WHY THIS IS COMMITTED. endospore-accountsdb-close-ce.sh, ssaid-userkey-seed.sh and systemui-no-restart-doze.sh edit
# trees we do not own and are silent when absent (AGENTS.md): no build break, no log line. Each is verified on a build
# or a device ONLY by a literal that docs/framework-patches.md's register names, so an edit to the text a script writes
# makes the register's check report "not carried" on a good build, or the reverse. Since NWP-20261004-01 an image
# missing accountsdb-close-ce even wipes cold-locked sessions. These checks run each script against a synthetic tree
# built from its own anchor text with a few lines of context either side, and pin:
#   - pristine -> exit 0, the end state present, and the register's verify literal present in the patched file
#     (systemui: also the original `Restarting sleep state` call ABSENT, the register's two-sided artifact check);
#   - a re-run -> exit 0 and the file byte-identical;
#   - a drifted anchor -> non-zero and the file byte-identical; a duplicated anchor -> non-zero for accountsdb-close-ce
#     and systemui (count != 1); a missing target file -> non-zero;
#   - accountsdb-close-ce: either required field line missing -> exit 2, unchanged.
#   - ssaid: a duplicated anchor -> non-zero, file byte-identical, no temp file (NWP-20261016-33); a second line that
#     only CONTAINS the anchor text (trailing comment) is not a site the awk replaces, so it does not count.
# ONE BEHAVIOUR IS PINNED AS IT IS TODAY, NOT AS IT SHOULD BE (backlog §B):
#   - systemui-no-restart-doze.sh runs `cp -n "$F" "$F.diaspore-orig"` BEFORE its anchor assert, so a REFUSED run
#     still writes a file, and a successful one leaves the copy in the tree.
# The register's cells are logcat lines, not source literals, so each literal is READ out of the register row (by the
# script's name) and normalised by one rule: take the backticked text after `logcat `; drop a leading `<Tag>: ` (the
# logcat tag, not part of the string); split at a <N>/<n> placeholder and require every fragment (the ssaid source
# builds its line around `+ userId +`); a fragment matches as a substring, so a work id the source appends and the
# register omits (`Nowhere: NOT restarting sleep state` before ` (NWP-20260825-03)`) still matches. A row, literal
# or fragment that cannot be extracted is EXTRACTION FAILED, exit 2.
# They cannot show that the anchors still match the real trees; the build host checks that (the register says how).
# CI runs this suite and its --mutate run. Needs python3, as the patches do.
#
#   bash test-framework-patch-anchors.sh            # the invariants
#   bash test-framework-patch-anchors.sh --mutate   # ... plus mutations of each script that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patches need it" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
REGISTER="$REPO/docs/framework-patches.md"
ACC0="$REPO/editions/endospore/build/patches/endospore-accountsdb-close-ce.sh"
SSAID0="$REPO/editions/diaspore/build/patches/ssaid-userkey-seed.sh"
SUI0="$REPO/editions/diaspore/build/patches/systemui-no-restart-doze.sh"

ACC_REL=frameworks/base/services/core/java/com/android/server/accounts/AccountsDb.java
SSAID_REL=frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java
SUI_REL=frameworks/base/packages/SystemUI/src/com/android/systemui/flags/RestartDozeListener.kt

# extract <script name>: the register's verify literal as fragments, one per line. Exit 2 when it cannot be read.
extract(){
python3 - "$REGISTER" "$1" <<'PY'
import re, sys
reg, name = sys.argv[1], sys.argv[2]
rows = [l for l in open(reg, encoding="utf-8").read().split("\n") if l.startswith("| `%s` |" % name)]
if len(rows) != 1:
    print("EXTRACTION FAILED: %d register rows for %s" % (len(rows), name), file=sys.stderr); sys.exit(2)
cell = rows[0].rstrip()
cell = cell[:-1].rstrip() if cell.endswith("|") else cell
cell = cell.split(" | ")[-1]
m = re.search(r"logcat `([^`]+)`", cell)
if not m:
    print("EXTRACTION FAILED: no `logcat `...`` literal in the %s row" % name, file=sys.stderr); sys.exit(2)
lit = re.sub(r"^[A-Z][A-Za-z]*: ", "", m.group(1), count=1)
frags = re.split(r"<[Nn]>", lit)
if not all(frags):
    print("EXTRACTION FAILED: an empty fragment in %r" % lit, file=sys.stderr); sys.exit(2)
print("\n".join(frags))
PY
}

# --- fixtures -------------------------------------------------------------------------------------------
tree_acc(){   # <dir> pristine|drift|dup|nofield1|nofield2
  local f="$1/$ACC_REL"; mkdir -p "$(dirname "$f")"
  local f1='    private CeDatabaseHelper mCeDatabase;' f2='        private volatile boolean mCeAttached;'
  local close='mDeDatabase.close();'
  [ "$2" = nofield1 ] && f1='    private CeDatabaseHelper mOtherDatabase;'
  [ "$2" = nofield2 ] && f2='        private volatile boolean mOtherFlag;'
  [ "$2" = drift ] && close='mDeDatabase.closeAll();'
  {
    echo 'package com.android.server.accounts;'; echo
    echo 'class AccountsDb implements AutoCloseable {'
    echo '    private static final String TAG = "AccountsDb";'; echo
    echo '    private final DeDatabaseHelper mDeDatabase;'
    echo "$f1"; echo
    echo '    static class DeDatabaseHelper extends SQLiteOpenHelper {'
    echo "$f2"
    echo '        private final int mUserId;'
    echo '    }'; echo
    local n=1; [ "$2" = dup ] && n=2
    for _ in $(seq "$n"); do
      echo '    @Override'; echo '    public void close() {'; echo "        $close"; echo '    }'; echo
    done
    echo '    boolean isCeDatabaseAttached() {'; echo '        return mDeDatabase.mCeAttached;'; echo '    }'; echo '}'
  } > "$f"
}
tree_ssaid(){   # <dir> pristine|drift|dup|near (near: a second line = anchor + trailing comment)
  local f="$1/$SSAID_REL"; mkdir -p "$(dirname "$f")"
  local a='            final String userKey = HexEncoding.encodeToString(keyBytes, true /* upperCase */);'
  [ "$2" = drift ] && a='            final String userKey = HexEncoding.encodeToString(keyBytes, false /* upperCase */);'
  gen(){
    echo '    private String generateUserKeyLocked(int userId) {'
    echo '        try {'
    echo '            final byte[] keyBytes = new byte[32];'
    echo '            sSecureRandom.nextBytes(keyBytes);'
    echo "$a"
    echo '            return userKey;'
    echo '        } catch (Exception e) {'
    echo '            return null;'
    echo '        }'
    echo '    }'; echo
  }
  {
    echo 'package com.android.providers.settings;'; echo
    echo 'public class SettingsProvider extends ContentProvider {'
    echo '    private static final String LOG_TAG = "SettingsProvider";'; echo
    gen
    [ "$2" = dup ] && gen
    [ "$2" = near ] && { echo "    // $a"; echo "$a // not a site"; }
    echo '}'
  } > "$f"
}
tree_sui(){   # <dir> pristine|drift|dup
  local f="$1/$SUI_REL"; mkdir -p "$(dirname "$f")"
  local call='Log.d("RestartDozeListener", "Restarting sleep state")'
  [ "$2" = drift ] && call='Log.d("RestartDozeListener", "Restarting the sleep state")'
  gen(){
    echo '    fun maybeRestartSleep() {'
    echo '        handler.postDelayed('
    echo '            {'
    echo '                if (settings.getBool(RESTART_SLEEP_KEY, false)) {'
    echo "                    $call"
    echo '                    powerManager.wakeUp('
    echo '                        systemClock.uptimeMillis(),'
    echo '                        PowerManager.WAKE_REASON_APPLICATION,'
    echo '                        "RestartDozeListener"'
    echo '                    )'
    echo '                    powerManager.goToSleep(systemClock.uptimeMillis())'
    echo '                }'
    echo '            },'
    echo '            1000L'
    echo '        )'
    echo '    }'; echo
  }
  {
    echo 'package com.android.systemui.flags'; echo
    echo 'class RestartDozeListener @Inject constructor() {'
    echo '    companion object { const val RESTART_SLEEP_KEY = "restart_nap_after_start" }'; echo
    gen
    [ "$2" = dup ] && gen
    echo '}'
  } > "$f"
}

# --- the checks -----------------------------------------------------------------------------------------
checks(){
  local W; W="$(mktemp -d)"
  ok(){ printf '  ok    %s\n' "$1"; }
  no(){ printf '  FAIL  %s\n' "$1"; }
  # ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q`.
  has(){ grep -cF -- "$2" "$1" >/dev/null; }
  lacks(){ ! grep -cF -- "$2" "$1" >/dev/null; }
  count(){ local n; n=$(grep -cF -- "$2" "$1"); echo "${n:-0}"; }
  chk(){ local d="$1"; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
  # run <sut> <tree>: exit code in RC, output in $W/<tree>.out.
  run(){ bash "$1" "$W/$2" > "$W/$2.out" 2>&1; RC=$?; }
  rc_is(){ [ "$RC" = "$1" ]; }
  rc_nonzero(){ [ "$RC" != 0 ]; }

  local lit fr
  # --- accountsdb-close-ce --------------------------------------------------------------------------------
  local f="$W/acc/$ACC_REL" lit_out
  lit_out=$(extract endospore-accountsdb-close-ce.sh) || { echo "  FAIL  EXTRACTION FAILED (accountsdb-close-ce)"; rm -rf "$W"; return 2; }
  mapfile -t lit <<<"$lit_out"
  tree_acc "$W/acc" pristine
  chk "accountsdb: pristine lacks the register literal" lacks "$f" "${lit[0]}"
  run "$ACC" acc
  chk "accountsdb: pristine -> exit 0" rc_is 0
  chk "accountsdb: close() closes the CE helper" has "$f" 'mCeDatabase.close();'
  chk "accountsdb: close() detaches CE" has "$f" 'mDeDatabase.mCeAttached = false;'
  for fr in "${lit[@]}"; do chk "accountsdb: register literal fragment present: $fr" has "$f" "$fr"; done
  cp "$f" "$W/acc.once"
  run "$ACC" acc
  chk "accountsdb: re-run -> exit 0" rc_is 0
  chk "accountsdb: re-run leaves the file byte-identical" cmp -s "$f" "$W/acc.once"
  chk "accountsdb: re-run says already patched" has "$W/acc.out" 'already patched'
  local v
  for v in drift:2 dup:2 nofield1:2 nofield2:2; do
    tree_acc "$W/acc_${v%%:*}" "${v%%:*}"; cp "$W/acc_${v%%:*}/$ACC_REL" "$W/acc_${v%%:*}.orig"
    run "$ACC" "acc_${v%%:*}"
    chk "accountsdb: ${v%%:*} -> exit ${v##*:}" rc_is "${v##*:}"
    chk "accountsdb: ${v%%:*} leaves the file byte-identical" cmp -s "$W/acc_${v%%:*}/$ACC_REL" "$W/acc_${v%%:*}.orig"
  done
  mkdir -p "$W/acc_missing"; run "$ACC" acc_missing
  chk "accountsdb: missing target file -> exit 1" rc_is 1

  # --- ssaid-userkey-seed ---------------------------------------------------------------------------------
  f="$W/ssaid/$SSAID_REL"
  lit_out=$(extract ssaid-userkey-seed.sh) || { echo "  FAIL  EXTRACTION FAILED (ssaid-userkey-seed)"; rm -rf "$W"; return 2; }
  mapfile -t lit <<<"$lit_out"
  local anchor='            final String userKey = HexEncoding.encodeToString(keyBytes, true /* upperCase */);'
  tree_ssaid "$W/ssaid" pristine
  chk "ssaid: pristine lacks the register literal" lacks "$f" "${lit[0]}"
  run "$SSAID" ssaid
  chk "ssaid: pristine -> exit 0" rc_is 0
  chk "ssaid: the stock anchor line is replaced" lacks "$f" "$anchor"
  chk "ssaid: the seed path is read" has "$f" '/nowhere-ssaid-seed"'
  for fr in "${lit[@]}"; do chk "ssaid: register literal fragment present: $fr" has "$f" "$fr"; done
  chk "ssaid: the literal's two fragments are the ones around userId" test "${#lit[@]}" = 2
  chk "ssaid: no temp file left behind" test ! -e "$f.nowhere.tmp"
  cp "$f" "$W/ssaid.once"
  run "$SSAID" ssaid
  chk "ssaid: re-run -> exit 0" rc_is 0
  chk "ssaid: re-run leaves the file byte-identical" cmp -s "$f" "$W/ssaid.once"
  chk "ssaid: re-run says already patched" has "$W/ssaid.out" 'already patched'
  tree_ssaid "$W/ssaid_drift" drift; cp "$W/ssaid_drift/$SSAID_REL" "$W/ssaid_drift.orig"
  run "$SSAID" ssaid_drift
  chk "ssaid: drifted anchor -> non-zero" rc_nonzero
  chk "ssaid: drifted anchor leaves the file byte-identical" cmp -s "$W/ssaid_drift/$SSAID_REL" "$W/ssaid_drift.orig"
  chk "ssaid: drifted anchor leaves no temp file" test ! -e "$W/ssaid_drift/$SSAID_REL.nowhere.tmp"
  tree_ssaid "$W/ssaid_dup" dup; cp "$W/ssaid_dup/$SSAID_REL" "$W/ssaid_dup.orig"
  run "$SSAID" ssaid_dup
  chk "ssaid: duplicated anchor -> non-zero" rc_nonzero
  chk "ssaid: duplicated anchor leaves the file byte-identical" cmp -s "$W/ssaid_dup/$SSAID_REL" "$W/ssaid_dup.orig"
  chk "ssaid: duplicated anchor leaves no temp file" test ! -e "$W/ssaid_dup/$SSAID_REL.nowhere.tmp"
  tree_ssaid "$W/ssaid_near" near
  run "$SSAID" ssaid_near
  chk "ssaid: a line that merely contains the anchor is not a second site -> exit 0" rc_is 0
  chk "ssaid: ... and the block is inserted once" test "$(count "$W/ssaid_near/$SSAID_REL" '/nowhere-ssaid-seed"')" = 1
  mkdir -p "$W/ssaid_missing"; run "$SSAID" ssaid_missing
  chk "ssaid: missing target file -> exit 1" rc_is 1

  # --- systemui-no-restart-doze ---------------------------------------------------------------------------
  f="$W/sui/$SUI_REL"
  lit_out=$(extract systemui-no-restart-doze.sh) || { echo "  FAIL  EXTRACTION FAILED (systemui-no-restart-doze)"; rm -rf "$W"; return 2; }
  mapfile -t lit <<<"$lit_out"
  tree_sui "$W/sui" pristine; cp "$f" "$W/sui.pristine"
  chk "systemui: pristine lacks the register literal" lacks "$f" "${lit[0]}"
  chk "systemui: pristine carries the original Restarting sleep state call" has "$f" 'Restarting sleep state'
  run "$SUI" sui
  chk "systemui: pristine -> exit 0" rc_is 0
  for fr in "${lit[@]}"; do chk "systemui: register literal fragment present: $fr" has "$f" "$fr"; done
  chk "systemui: the original Restarting sleep state call is ABSENT" lacks "$f" 'Restarting sleep state'
  chk "systemui: the wakeUp/goToSleep pair is gone" lacks "$f" 'powerManager.goToSleep'
  chk "systemui: the if and its settings read are kept" has "$f" 'if (settings.getBool(RESTART_SLEEP_KEY, false)) {'
  # PINNED TODAY'S BEHAVIOUR: a pristine copy is left in the tree.
  chk "systemui: leaves <file>.diaspore-orig in the tree (recorded)" test -f "$f.diaspore-orig"
  chk "systemui: the .diaspore-orig copy is the pristine file" cmp -s "$f.diaspore-orig" "$W/sui.pristine"
  cp "$f" "$W/sui.once"
  run "$SUI" sui
  chk "systemui: re-run -> exit 0" rc_is 0
  chk "systemui: re-run leaves the file byte-identical" cmp -s "$f" "$W/sui.once"
  chk "systemui: re-run says already applied" has "$W/sui.out" 'already applied'
  chk "systemui: re-run leaves the .diaspore-orig copy untouched" cmp -s "$f.diaspore-orig" "$W/sui.pristine"
  for v in drift dup; do
    tree_sui "$W/sui_$v" "$v"; cp "$W/sui_$v/$SUI_REL" "$W/sui_$v.orig"
    run "$SUI" "sui_$v"
    chk "systemui: $v -> non-zero" rc_nonzero
    chk "systemui: $v leaves the file byte-identical" cmp -s "$W/sui_$v/$SUI_REL" "$W/sui_$v.orig"
    # PINNED TODAY'S BEHAVIOUR (backlog): cp -n runs before the python assert, so a REFUSED run writes a file.
    chk "systemui: $v still writes <file>.diaspore-orig (cp -n precedes the assert; recorded)" test -f "$W/sui_$v/$SUI_REL.diaspore-orig"
  done
  mkdir -p "$W/sui_missing"; run "$SUI" sui_missing
  chk "systemui: missing target file -> non-zero" rc_nonzero
  chk "systemui: missing target file writes nothing" test -z "$(find "$W/sui_missing" -type f)"
  rm -rf "$W"
}

# run_checks: the checks with the current $ACC/$SSAID/$SUI; output in $OUT, FAIL lines counted into NFAIL.
run_checks(){ OUT=$(checks 2>&1); local rc=$?; NFAIL=$(grep -c '^  FAIL' <<<"$OUT"); [ "$rc" = 2 ] && NFAIL=$((NFAIL+1)); return 0; }

ACC="$ACC0"; SSAID="$SSAID0"; SUI="$SUI0"
run_checks
printf '%s\n' "$OUT"
NPASS=$(grep -c '^  ok' <<<"$OUT")
echo "== $NPASS passed, $NFAIL failed"
[ "$NFAIL" = 0 ] || exit 1

if [ "$MUTATE" = yes ]; then
  echo "== mutations (each must CONVICT the suite)"
  M="$(mktemp -d)"; trap 'rm -rf "$M"' EXIT
  LOST=0
  # mutant <label> <script var: ACC|SSAID|SUI> <old text> <new text>: replace the text once (it must exist), rerun.
  mutant(){
    local label="$1" var="$2" old="$3" new="$4" src dst="$M/$2.sh"
    case "$var" in ACC) src="$ACC0" ;; SSAID) src="$SSAID0" ;; SUI) src="$SUI0" ;; esac
    if ! python3 - "$src" "$dst" "$old" "$new" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
if s.count(sys.argv[3]) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4], 1))
PY
    then echo "  FAIL  mutant did not apply: $label"; LOST=$((LOST+1)); return; fi
    ACC="$ACC0"; SSAID="$SSAID0"; SUI="$SUI0"
    printf -v "$var" '%s' "$dst"
    run_checks
    if [ "$NFAIL" -gt 0 ]; then echo "  ok    convicted: $label ($NFAIL checks failed)"
    else echo "  FAIL  NOT convicted: $label"; LOST=$((LOST+1)); fi
  }
  mutant "accountsdb: the logged literal edited" ACC 'Slog.i(TAG, "nowhere: closed the CE accounts db' 'Slog.i(TAG, "nowhere: closed CE accounts db'
  mutant "accountsdb: the idempotence marker check removed" ACC 'if MARK in s:' 'if False:'
  mutant "accountsdb: the anchor count relaxed to >= 1" ACC 'if s.count(anchor) != 1:' 'if s.count(anchor) < 1:'
  mutant "ssaid: the logged literal edited" SSAID 'nowhere: seeded ssaid userkey for user ' 'nowhere: seeded the ssaid userkey for user '
  mutant "ssaid: the anchor count check removed" SSAID 'elif [ "$ANCHOR_N" -ne 1 ]; then' 'elif false; then'
  mutant "ssaid: the count relaxed to >= 1" SSAID 'elif [ "$ANCHOR_N" -ne 1 ]; then' 'elif [ "$ANCHOR_N" -lt 1 ]; then'
  mutant "ssaid: the count taken by substring, not whole line" SSAID 'grep -cxF -- "$ANCHOR"' 'grep -cF -- "$ANCHOR"'
  mutant "ssaid: the idempotence marker check removed" SSAID 'if grep -qF "$MARKER" "$SP"; then' 'if false; then'
  mutant "systemui: the logged literal edited" SUI 'Nowhere: NOT restarting sleep state' 'Nowhere: not restarting sleep state'
  mutant "systemui: the idempotence marker check removed" SUI 'if grep -q "NWP-20260825-03" "$F"; then' 'if false; then'
  mutant "systemui: the anchor count relaxed to >= 1" SUI 'assert s.count(anchor) == 1' 'assert s.count(anchor) >= 1'
  [ "$LOST" = 0 ] || { echo "== $LOST mutant(s) not convicted"; exit 1; }
  echo "== every mutant convicted"
fi
exit 0
