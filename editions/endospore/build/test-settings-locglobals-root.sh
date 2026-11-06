#!/usr/bin/env bash
# test-settings-locglobals-root.sh [--mutate] -- NWP-20261101-25.
#
# WHY THIS IS COMMITTED. patches/endospore-settings-locglobals-root.sh opens GrapheneOS's protected-settings guard
# (SettingsProvider.checkProtectedSettingAccess) for ONE caller and TWO keys: uid root, package "root" (roamd's
# `cmd settings`), writing Settings.Global network_location or geocoder. build-device.sh applies it to every Endospore
# build through its patches glob, and off the device only this suite reads what it inserts. Two failures are silent:
# an anchor that stops matching (no exception, and the claim reads back NOT APPLIED, as on frankel 0.5.50,
# NW-cdd075c0ac79), and an exception that is WIDER than decided -- any key, a read, any uid, any package -- which no
# build and no device check would notice, because every wider guard still lets the two keys through.
# The fixture is the real checkProtectedSettingAccess, copied verbatim from the GrapheneOS 2026061600 tree
# (frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java ~:2560-2621),
# inside a minimal class holding the one field it needs. The expected exception block is written out below, by hand,
# independently of the script. The suite pins:
#   (a) pristine -> exit 0, the file equal to the pristine one plus exactly the expected block after the shell
#       exemption (nothing else changed), the MARK and the log literal once each;
#   (b) a re-run -> exit 0, `already patched`, byte-identical;
#   (c) the inserted condition, split at its top-level `&&`, is exactly five conjuncts, and each one is checked by
#       name: c1 a write (`!isRead`), c2 uid root, c3 package "root", c4 the key is Settings.Global.NETWORK_LOCATION or
#       Settings.Global.GEOCODER, c5 by the constants (no "network_location" / "geocoder" string literal in the block),
#       c6 the Global map, c7 nothing more and the block's one `return;` follows its one Slog.d;
#   (d) the shell-exemption anchor drifted -> exit 2, byte-identical; (e) the anchor twice -> exit 2, byte-identical;
#   (f) the method signature drifted -> exit 2, byte-identical; (g) the only shell exemption lies in ANOTHER method
#       -> exit 2, byte-identical; (h) SettingsProvider.java missing -> exit 1;
#   (i) patch-markers.tsv's `need` literal for this script is in the patched file.
# Synthetic trees only: that the anchor still matches the real GrapheneOS file is the build host's to check (the
# register in docs/framework-patches.md says how). CI runs this suite and its --mutate run. Needs python3, as the patch.
#
#   bash test-settings-locglobals-root.sh            # the cases
#   bash test-settings-locglobals-root.sh --mutate   # ... plus mutants of the script that must each CONVICT the named case
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRIPT0="$REPO/editions/endospore/build/patches/endospore-settings-locglobals-root.sh"
TSV="$REPO/editions/endospore/build/patch-markers.tsv"
SP_REL=frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java
MARK='NWP-20261101-25 (nowhere/endospore)'
LOGLIT='nowhere: allowed root to write protected setting '

# --- fixtures, written once ---------------------------------------------------------------------------------------
FIX=$(mktemp -d -p "$W") || exit 2
# The real method, verbatim from the GrapheneOS tree.
cat > "$FIX/method" <<'JAVA'
    private void checkProtectedSettingAccess(boolean isRead, String name, ArrayMap<String, Settings.ProtectedSetting> map) {
        Settings.ProtectedSetting protSetting = map.get(name);
        if (protSetting == null) {
            return;
        }
        if (isRead && !protSetting.restrictReads()) {
            return;
        }
        if (Binder.getCallingPid() == Process.myPid()) {
            // SettingsProvider runs in system_server process
            return;
        }
        String callingPackage = getCallingPackage();
        if (callingPackage == null) {
            if (Build.IS_DEBUGGABLE) {
                if (Binder.getCallingUid() == ROOT_UID) {
                    Slog.d(LOG_TAG, "allowed root to access protected setting " + protSetting.key());
                    return;
                }
            }
            throw new SecurityException("callingPackage is null when accessing protected setting " + protSetting.key());
        }
        var ksp = KnownSystemPackages.get(requireContext());

        for (int id : protSetting.readWritableBy()) {
            if (callingPackage.equals(ksp.getById(id))) {
                return;
            }
        }
        if (isRead) {
            for (int id : protSetting.readableBy()) {
                if (callingPackage.equals(ksp.getById(id))) {
                    return;
                }
            }
        }

        if (ksp.shell.equals(callingPackage)) {
            // ADB is used for testing
            Slog.d(LOG_TAG, "allowed shell to access protected setting " + protSetting.key());
            return;
        }

        if (Build.IS_DEBUGGABLE) {
            String systemUiTests = "com.android.systemui.tests";
            if (isRead && systemUiTests.equals(callingPackage)) {
                ApplicationInfo ai = getCallingApplicationInfoOrThrow();
                if (ai.isSignedWithPlatformKey() && (ai.flags & ApplicationInfo.FLAG_TEST_ONLY) != 0) {
                    // SystemUI tests run SystemUI code, so it should be able to read
                    // SystemUI-readable settings
                    for (int id : protSetting.readableBy()) {
                        if (id == KnownSystemPackage.SYSTEM_UI) {
                            Slog.d(LOG_TAG, "allowed " + systemUiTests + " to read protected setting " + protSetting.key());
                            return;
                        }
                    }
                }
            }
        }

        throw new SecurityException(callingPackage + " is not allowed to access protected setting " + protSetting.key());
    }
JAVA
# The block the patch must insert after the shell exemption, written out independently of the script.
cat > "$FIX/block" <<'JAVA'

        // NWP-20261101-25 (nowhere/endospore): roamd (init's nowhere_roamd service, uid root) is the one writer of the
        // session-scoped location globals: it claims these two keys for the profile in front and restores the baseline
        // when that session ends. `cmd settings` from uid 0 names its package "root" (SettingsService), which no list
        // above holds, so this guard refused every such write on every build type. Allow exactly that caller to WRITE
        // exactly these two Global keys; any other key, any read and any other caller are refused as before.
        if (!isRead && Binder.getCallingUid() == ROOT_UID && "root".equals(callingPackage)
                && map == sProtectedGlobalSettings
                && (Settings.Global.NETWORK_LOCATION.equals(name) || Settings.Global.GEOCODER.equals(name))) {
            Slog.d(LOG_TAG, "nowhere: allowed root to write protected setting " + name + " (NWP-20261101-25)");
            return;
        }
JAVA
python3 -I - "$FIX" <<'PY' || exit 2
import sys
fix = sys.argv[1]
def fail(msg):
    print("FIXTURE FAILED: " + msg, file=sys.stderr); sys.exit(2)
def rd(n): return open(fix + "/" + n, encoding="utf-8", newline="").read()
def put(n, t): open(fix + "/" + n, "w", encoding="utf-8", newline="").write(t)
method, block = rd("method"), rd("block")
ANCHOR = ('        if (ksp.shell.equals(callingPackage)) {\n            // ADB is used for testing\n'
          '            Slog.d(LOG_TAG, "allowed shell to access protected setting " + protSetting.key());\n'
          '            return;\n        }\n')
SIG = ('    private void checkProtectedSettingAccess(boolean isRead, String name, '
       'ArrayMap<String, Settings.ProtectedSetting> map) {\n')
if method.count(ANCHOR) != 1: fail("the method holds the shell exemption %d times" % method.count(ANCHOR))
if not method.startswith(SIG): fail("the method does not start with its signature")
if "NWP-" in method or "nowhere" in method: fail("the method fixture is not pristine")
head = ("package com.android.providers.settings;\n\n"
        "import static android.os.Process.ROOT_UID;\n\n"
        "import android.os.Binder;\nimport android.os.Build;\nimport android.os.Process;\n"
        "import android.provider.Settings;\nimport android.util.ArrayMap;\nimport android.util.Slog;\n\n"
        "public class SettingsProvider extends ContentProvider {\n"
        "    private static final String LOG_TAG = \"SettingsProvider\";\n\n"
        "    private static final ArrayMap<String, Settings.ProtectedSetting> sProtectedGlobalSettings =\n"
        "            new ArrayMap<>();\n\n")
tail = "\n    private void after() {\n        return;\n    }\n}\n"
pristine = head + method + tail
put("pristine", pristine)
put("expected", pristine.replace(ANCHOR, ANCHOR + block, 1))
put("drift", pristine.replace("            // ADB is used for testing\n", "            // ADB is used for tests\n", 1))
dup_method = method.replace(ANCHOR, ANCHOR + "\n" + ANCHOR, 1)
put("dup", head + dup_method + tail)
put("nosig", pristine.replace("boolean isRead, String name,", "boolean isRead, String key, String name,", 1))
# The shell exemption moved out: the method loses it and a later method carries it.
outside = head + method.replace(ANCHOR, "", 1) + "\n    private void other(String callingPackage) {\n" + ANCHOR + "    }\n" + tail
put("outside", outside)
for n in ("drift", "dup", "nosig", "outside"):
    if rd(n) == pristine: fail("variant %s equals pristine" % n)
PY

NFAIL=0; OUT_ALL=""; RC=0; OUT=""; SCRIPT="$SCRIPT0"

# mktree <fixture|->: a new tree under $W holding a copy of the fixture as SettingsProvider.java ('-' = absent).
mktree(){
  local t; t=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$t/$(dirname "$SP_REL")"
  [ "$1" = - ] || cp "$FIX/$1" "$t/$SP_REL"
  printf '%s\n' "$t"
}
runp(){ OUT=$(bash "$SCRIPT" "$1" 2>&1); RC=$?; }
snap(){ local s; s=$(mktemp -p "$W") || exit 2; cp "$1" "$s"; printf '%s\n' "$s"; }
check(){
  local c="$1" d="$2"; shift 2
  if "$@"; then OUT_ALL="$OUT_ALL  ok    ($c) $d"$'\n'; else OUT_ALL="$OUT_ALL  FAIL  ($c) $d"$'\n'; NFAIL=$((NFAIL + 1)); fi
}
rc_is(){ [ "$RC" = "$1" ]; }
has(){ [[ $OUT == *"$1"* ]]; }
same(){ cmp -s "$1" "$2"; }
count1(){ python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]) == 1 else 1)' "$1" "$2"; }
# cond <patched file> <check>: one property of the block the patch inserted after the shell exemption.
cond(){
  python3 -I - "$1" "$2" <<'PY'
import sys
f, which = sys.argv[1], sys.argv[2]
s = open(f, encoding="utf-8").read()
ANCHOR_END = ('            Slog.d(LOG_TAG, "allowed shell to access protected setting " + protSetting.key());\n'
              '            return;\n        }\n')
NEXT = "        if (Build.IS_DEBUGGABLE) {\n"
if s.count(ANCHOR_END) != 1: sys.exit(1)
i = s.index(ANCHOR_END) + len(ANCHOR_END)
j = s.find(NEXT, i)
if j < 0: sys.exit(1)
block = s[i:j]
code = "\n".join(l for l in block.split("\n") if not l.strip().startswith("//"))
k = code.find("if (")
e = code.find(") {\n", k)
if k < 0 or e < 0: sys.exit(1)
c = " ".join(code[k + 4:e].split())
# Split at top-level && only.
parts, depth, cur, n = [], 0, "", 0
while n < len(c):
    ch = c[n]
    if ch == "(": depth += 1
    if ch == ")": depth -= 1
    if depth == 0 and c.startswith(" && ", n):
        parts.append(cur); cur = ""; n += 4; continue
    cur += ch; n += 1
parts.append(cur)
want = {
    "c1": "!isRead",
    "c2": "Binder.getCallingUid() == ROOT_UID",
    "c3": '"root".equals(callingPackage)',
    "c4": "(Settings.Global.NETWORK_LOCATION.equals(name) || Settings.Global.GEOCODER.equals(name))",
    "c6": "map == sProtectedGlobalSettings",
}
if which in want:
    sys.exit(0 if parts.count(want[which]) == 1 else 1)
if which == "c5":
    sys.exit(0 if '"network_location"' not in block and '"geocoder"' not in block else 1)
if which == "c7":
    body = code[e + 4:]
    ok = (sorted(parts) == sorted(want.values()) and body.count("return;") == 1 and body.count("Slog.d(") == 1
          and body.index("Slog.d(") < body.index("return;") and code.count("if (") == 1)
    sys.exit(0 if ok else 1)
sys.exit(2)
PY
}
tsv_need_in(){
  python3 -I - "$TSV" "$1" <<'PY'
import sys
tsv, f = sys.argv[1], sys.argv[2]
rows = [l.rstrip("\n").split("\t") for l in open(tsv, encoding="utf-8") if l.strip() and not l.startswith("#")]
need = [r[3] for r in rows if len(r) == 4 and r[0] == "endospore-settings-locglobals-root.sh" and r[2] == "need"]
s = open(f, encoding="utf-8").read()
sys.exit(0 if need and all(n in s for n in need) else 1)
PY
}

run_checks(){
  NFAIL=0; OUT_ALL=""
  local t F F1 v d
  # (a) pristine
  t=$(mktree pristine); F="$t/$SP_REL"
  runp "$t"
  check a "pristine: exit 0" rc_is 0
  check a "the file is the pristine one plus exactly the expected block (nothing else changed)" same "$F" "$FIX/expected"
  check a "the MARK appears once" count1 "$F" "$MARK"
  check a "the log literal appears once" count1 "$F" "$LOGLIT"
  # (c) the condition, conjunct by conjunct
  for v in c1 c2 c3 c4 c5 c6 c7; do
    case $v in
      c1) d="a write only: !isRead" ;; c2) d="uid root only" ;; c3) d='package "root" only' ;;
      c4) d="NETWORK_LOCATION or GEOCODER only" ;; c5) d="by the constants: no key string literal in the block" ;;
      c6) d="the Global map only" ;; c7) d="exactly those five conjuncts, one Slog.d then one return" ;;
    esac
    check "$v" "$d" cond "$F" "$v"
  done
  # (i) the marker table's literal is what the patch writes
  check i "patch-markers.tsv's need literal is in the patched file" tsv_need_in "$F"
  # (b) re-run
  F1=$(snap "$F")
  runp "$t"
  check b "re-run: exit 0" rc_is 0
  check b "re-run says already patched" has "already patched"
  check b "re-run: byte-identical" same "$F" "$F1"
  # (d)-(g) refusals
  for v in d:drift e:dup f:nosig g:outside; do
    t=$(mktree "${v#*:}"); F="$t/$SP_REL"
    runp "$t"
    check "${v%%:*}" "${v#*:}: exit 2" rc_is 2
    check "${v%%:*}" "${v#*:}: says aborting" has "aborting"
    check "${v%%:*}" "${v#*:}: byte-identical" same "$F" "$FIX/${v#*:}"
  done
  # (h) the file missing
  t=$(mktree -)
  runp "$t"
  check h "SettingsProvider.java absent: exit 1" rc_is 1
  check h "SettingsProvider.java absent: says MISSING" has MISSING
  check h "SettingsProvider.java absent: nothing written" bash -c '[ ! -e "$1" ]' _ "$t/$SP_REL"
}

python3 --version
SCRIPT="$SCRIPT0"; run_checks
printf '%s' "$OUT_ALL"
echo "== $(printf '%s' "$OUT_ALL" | grep -c '^  ok') passed, $NFAIL failed"
[ "$NFAIL" = 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

LOST=0
# mutant <id> <convicting case> <old> <new>
mutant(){
  local id="$1" case_="$2" old="$3" new="$4" m; m=$(mktemp -p "$W") || exit 2
  if ! python3 -I - "$SCRIPT0" "$m" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8", newline="").read()
if s.count(old) != 1 or old == new:
    sys.exit(1)
open(dst, "w", encoding="utf-8", newline="").write(s.replace(old, new, 1))
PY
  then echo "  FAIL  mutant did not apply: $id"; LOST=$((LOST + 1)); return; fi
  cmp -s "$SCRIPT0" "$m" && { echo "  FAIL  mutant $id changed nothing"; LOST=$((LOST + 1)); return; }
  SCRIPT="$m"; run_checks
  if [[ $OUT_ALL == *"  FAIL  ($case_)"* ]]; then echo "  ok    convicted: $id by ($case_)"
  else echo "  FAIL  NOT convicted: $id (expected a failure in ($case_))"; printf '%s' "$OUT_ALL"; LOST=$((LOST + 1)); fi
  rm -f "$m"
}
echo "== mutants"
mutant M1-any-access c1 'if (!isRead && Binder.getCallingUid()' 'if (Binder.getCallingUid()'
mutant M2-any-uid c2 'Binder.getCallingUid() == ROOT_UID && "root"' '"root"'
mutant M3-any-key c4 '
                && (Settings.Global.NETWORK_LOCATION.equals(name) || Settings.Global.GEOCODER.equals(name))) {' ') {'
mutant M4-string-literal c5 'Settings.Global.NETWORK_LOCATION.equals(name)' '"network_location".equals(name)'
mutant M5-skip-on-missing-anchor d '% s.count(anchor)); sys.exit(2)' '% s.count(anchor)); sys.exit(0)'
mutant M6-any-package c3 ' && "root".equals(callingPackage)' ''
mutant M7-any-table c6 '
                && map == sProtectedGlobalSettings' ''
mutant M8-mark-never-matches b "MARK = 'NWP-20261101-25 (nowhere/endospore)'" "MARK = 'NWP-20261101-25 (nowhere/endospore) v2'"
mutant M9-no-method-scope g 'if not (start < s.index(anchor) < end):' 'if False:'
mutant M10-debuggable-or c7 'if (!isRead && Binder.getCallingUid()' 'if (Build.IS_DEBUGGABLE || !isRead && Binder.getCallingUid()'
[ "$LOST" = 0 ] || { echo "== $LOST mutant(s) not convicted"; exit 1; }
echo "== every mutant convicted"
