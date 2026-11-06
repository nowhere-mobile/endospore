#!/usr/bin/env bash
# test-ams-account-reload.sh [--mutate] -- NWP-20261026-17.
#
# WHY THIS IS COMMITTED. patches/endospore-ams-account-reload.sh is the #732 account-destruction hotfix (the
# detach-user / reload-user verbs roamd uses, with the PRE-construction strip of stale auth-uid mappings). build-device.sh
# applies it to every Endospore build through its patches glob, and patch-markers.tsv exempts it from the artifact check,
# so off the device nothing else checks it. An edit that breaks its upgrade arm or its brace match leaves a tree carrying
# the pre-#732 reloadUserAccounts in every later image with "already patched" or a green build, and roamed Google accounts
# are destroyed at sign-in again, with no build break and no log line until a device loses an account.
# The suite runs the script on synthetic trees built from the script's OWN anchor text (the AMS `anchor`, the `methods`
# blob and the three ShellCommand replacement anchors are extracted from it, so a fixture cannot drift; a text that cannot
# be extracted is EXTRACTION FAILED, exit 2) and pins:
#   (a) pristine -> exit 0, the PRE-strip and the method present once, the ShellCommand verbs and help lines present;
#   (b) a re-run -> exit 0, both files `already patched` and byte-identical;
#   (c) an older-cut reloadUserAccounts (no `pre-strip removed `) -> UPGRADED, the method byte-for-byte the canonical one,
#       the rest of the file unchanged;
#   (d) an older cut whose braces do not balance -> exit 2, AMS byte-identical;
#   (e) the AMS anchor missing -> exit 2, both files byte-identical;
#   (f) a ShellCommand anchor missing (each of the three) -> exit 2, ShellCommand byte-identical;
#   (g) either file missing -> exit 1, the other untouched.
# ONE BEHAVIOUR IS PINNED AS IT IS TODAY: the script writes AMS before its ShellCommand block runs, so (f) leaves AMS
# PATCHED, and a re-run skips AMS, finds the anchor still missing and exits 2 again. It does not matter in practice (the
# build fails on exit 2 either way, and the half-patched tree never reaches an image), but it is recorded, not fixed.
# The script is a bash build-host script, always launched with `bash`, so the cases run it with bash only. Synthetic trees
# only: that the anchors still match the real GrapheneOS tree is the build host's to check.
#
#   bash test-ams-account-reload.sh            # the cases
#   bash test-ams-account-reload.sh --mutate   # ... plus mutants of the script that must each CONVICT the named case
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRIPT0="$REPO/editions/endospore/build/patches/endospore-ams-account-reload.sh"
AMS_REL=frameworks/base/services/core/java/com/android/server/accounts/AccountManagerService.java
SHL_REL=frameworks/base/services/core/java/com/android/server/accounts/AccountManagerServiceShellCommand.java
SIG='void reloadUserAccounts(int userId)'
MARK='pre-strip removed '

# Fixtures, extracted ONCE from the original script (a mutant copy never moves them).
FIX=$(mktemp -d -p "$W") || exit 2
python3 -I - "$SCRIPT0" "$FIX" <<'PY' || exit 2
import ast, re, sys
script, fix = sys.argv[1], sys.argv[2]
def fail(msg):
    print("EXTRACTION FAILED: " + msg, file=sys.stderr); sys.exit(2)
try:
    src = open(script, encoding="utf-8").read()
except OSError as e:
    fail(str(e))
bodies = re.findall(r"<<'PY'\n(.*?)\nPY\n", src, re.S)
if len(bodies) != 2:
    fail("%d python heredocs in the script, expected 2" % len(bodies))
def assigns(body, names):
    tree = ast.parse(body)
    out = {}
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id in names:
            out[n.targets[0].id] = ast.literal_eval(n.value)
    for k in names:
        if k not in out:
            fail("no module-level `%s` in the script" % k)
    return out
try:
    a = assigns(bodies[0], ["anchor", "methods"])
    r = assigns(bodies[1], ["reps"])
except (SyntaxError, ValueError) as e:
    fail("cannot parse the script's heredocs: %s" % e)
anchor, methods, reps = a["anchor"], a["methods"], r["reps"]
if not (isinstance(anchor, str) and isinstance(methods, str)):
    fail("anchor/methods are not strings")
if not (isinstance(reps, list) and len(reps) == 3 and all(isinstance(t, tuple) and len(t) == 2 and all(isinstance(x, str) for x in t) for t in reps)):
    fail("reps is not three (old, new) string pairs")
SIG = "void reloadUserAccounts(int userId)"
TAIL = "\n\n    @VisibleForTesting\n    void onUserUnlocked"
if methods.count(SIG) != 1: fail("`%s` occurs %d times in methods" % (SIG, methods.count(SIG)))
if methods.count(TAIL) != 1: fail("the method end marker occurs %d times in methods" % methods.count(TAIL))
if "pre-strip removed " not in methods: fail("methods lacks the PRE-strip marker")
if anchor.count(TAIL) != 1: fail("anchor lacks the method end marker")
ms, me = methods.index(SIG), methods.index(TAIL)
if me < ms: fail("method end precedes its start")
if not methods.startswith(anchor[:anchor.index(TAIL)]): fail("methods does not start with the anchor's text")
for i, (old, new) in enumerate(reps):
    if old.split("\n")[0] not in new: fail("reps[%d] new text lacks its old first line" % i)
canonical = methods[ms:me]

head = "package com.android.server.accounts;\n\npublic class AccountManagerService {\n    void purgeUserData(int userId) {\n        synchronized (mUsers) {\n"
ams_pristine = head + anchor + "\n        // body\n    }\n}\n"
if ams_pristine.count(anchor) != 1: fail("pristine AMS holds the anchor %d times" % ams_pristine.count(anchor))
for bad in (SIG, "pre-strip removed "):
    if bad in ams_pristine: fail("pristine AMS already holds " + bad)
ams_fresh = ams_pristine.replace(anchor, methods, 1)
old_method = (SIG + " {\n        synchronized (mUsers) {\n            {\n                x();\n            }\n"
              "            try {\n                y();\n            } catch (Throwable t) {\n                z();\n            }\n        }\n"
              "        // post-construction strip only\n        strip();\n    }")
ams_old = ams_pristine.replace(anchor, methods[:ms] + old_method + methods[me:], 1)
if ams_old == ams_fresh or "pre-strip removed " in ams_old: fail("older-cut fixture is not an older cut")
ams_unbal = head.replace("void purgeUserData(int userId) {\n        synchronized (mUsers) {\n", "") + "    " + SIG + " {\n        synchronized (mUsers) {\n            x();\n    }\n"
ams_drift = ams_pristine.replace("void onUserUnlocked(Intent intent) {", "void onUserUnlocked(Intent intent, int flags) {", 1)
if ams_drift == ams_pristine or anchor in ams_drift: fail("drift fixture still holds the anchor")

shl_pristine = ("package com.android.server.accounts;\n\nclass AccountManagerServiceShellCommand {\n    public int onCommand(String cmd) {\n        switch (cmd) {\n"
                + reps[0][0] + "\n    }\n\n" + reps[1][0] + "\n        return null;\n    }\n\n    private void onHelp() {\n        pw.println(\"x\");\n"
                + reps[2][0] + "\n")
if "runReloadUser" in shl_pristine: fail("pristine ShellCommand already patched")
for i, (old, _) in enumerate(reps):
    if shl_pristine.count(old) != 1: fail("pristine ShellCommand holds reps[%d] old %d times" % (i, shl_pristine.count(old)))
shl_fresh = shl_pristine
for old, new in reps:
    shl_fresh = shl_fresh.replace(old, new, 1)

def put(name, text):
    open(fix + "/" + name, "w", encoding="utf-8").write(text)
put("canonical", canonical); put("ams_pristine", ams_pristine); put("ams_fresh", ams_fresh); put("ams_old", ams_old)
put("ams_unbal", ams_unbal); put("ams_drift", ams_drift); put("shl_pristine", shl_pristine); put("shl_fresh", shl_fresh)
for i, (old, _) in enumerate(reps):
    d = shl_pristine.replace(old, old.replace(old.split("\n")[0], old.split("\n")[0] + " // drifted", 1), 1)
    if d == shl_pristine or old in d: fail("drift fixture %d still holds reps[%d]" % (i, i))
    put("shl_drift%d" % i, d)
PY

NFAIL=0; OUT_ALL=""; RC=0; OUT=""; SCRIPT="$SCRIPT0"

# mktree <ams fixture|-> <shl fixture|->: a new tree under $W holding copies of the fixtures ('-' = file absent).
mktree(){
  local t; t=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$t/$(dirname "$AMS_REL")"
  [ "$1" = - ] || cp "$FIX/$1" "$t/$AMS_REL"
  [ "$2" = - ] || cp "$FIX/$2" "$t/$SHL_REL"
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
holds(){ grep -qF -- "$2" "$1"; }
method_is_canonical(){
  python3 -I - "$1" "$FIX/canonical" "$FIX/ams_old" <<'PY'
import sys
t, c, o = (open(p, encoding="utf-8").read() for p in sys.argv[1:4])
SIG = "void reloadUserAccounts(int userId)"; TAIL = "\n\n    @VisibleForTesting\n    void onUserUnlocked"
i = t.index(SIG); j = t.index(TAIL, i); oi = o.index(SIG); oj = o.index(TAIL, oi)
sys.exit(0 if t[i:j] == c and t[:i] == o[:oi] and t[j:] == o[oj:] else 1)
PY
}

run_checks(){
  NFAIL=0; OUT_ALL=""
  local t A S A1 S1 A2 S2 i
  # (a) pristine
  t=$(mktree ams_pristine shl_pristine); A="$t/$AMS_REL"; S="$t/$SHL_REL"
  runp "$t"
  check a "pristine: exit 0" rc_is 0
  check a "AMS is the fresh apply" same "$A" "$FIX/ams_fresh"
  check a "AMS holds the PRE-strip marker once" count1 "$A" "$MARK"
  check a "AMS holds reloadUserAccounts once" count1 "$A" "$SIG"
  check a "ShellCommand is the fresh apply" same "$S" "$FIX/shl_fresh"
  check a "ShellCommand holds runReloadUser" holds "$S" runReloadUser
  check a "ShellCommand help lists detach-user" holds "$S" '"  detach-user USER_ID"'
  check a "ShellCommand help lists reload-user" holds "$S" '"  reload-user USER_ID"'
  # (b) re-run
  A1=$(snap "$A"); S1=$(snap "$S")
  runp "$t"
  check b "re-run: exit 0" rc_is 0
  check b "AMS already patched" has "AccountManagerService already patched"
  check b "ShellCommand already patched" has "ShellCommand already patched"
  check b "AMS byte-identical" same "$A" "$A1"
  check b "ShellCommand byte-identical" same "$S" "$S1"
  # (c) the older cut
  t=$(mktree ams_old shl_fresh); A="$t/$AMS_REL"; S="$t/$SHL_REL"
  runp "$t"
  check c "older cut: exit 0" rc_is 0
  check c "output says UPGRADED" has UPGRADED
  check c "the method is byte-for-byte the canonical one, the rest unchanged" method_is_canonical "$A"
  check c "AMS holds the PRE-strip marker once" count1 "$A" "$MARK"
  check c "ShellCommand unchanged" same "$S" "$FIX/shl_fresh"
  # (d) unbalanced older cut
  t=$(mktree ams_unbal shl_pristine); A="$t/$AMS_REL"; S="$t/$SHL_REL"
  runp "$t"
  check d "unbalanced braces: exit 2" rc_is 2
  check d "output says could not brace-match" has "could not brace-match"
  check d "AMS byte-identical" same "$A" "$FIX/ams_unbal"
  check d "ShellCommand byte-identical" same "$S" "$FIX/shl_pristine"
  # (e) AMS anchor missing
  t=$(mktree ams_drift shl_pristine); A="$t/$AMS_REL"; S="$t/$SHL_REL"
  runp "$t"
  check e "AMS anchor missing: exit 2" rc_is 2
  check e "output says AccountManagerService ANCHOR NOT FOUND" has "AccountManagerService ANCHOR NOT FOUND"
  check e "AMS byte-identical" same "$A" "$FIX/ams_drift"
  check e "ShellCommand byte-identical" same "$S" "$FIX/shl_pristine"
  # (f) ShellCommand anchor missing (pinned as is: AMS is left patched)
  for i in 0 1 2; do
    t=$(mktree ams_pristine "shl_drift$i"); A="$t/$AMS_REL"; S="$t/$SHL_REL"
    runp "$t"
    check f "anchor $i missing: exit 2" rc_is 2
    check f "anchor $i: output says ShellCommand ANCHOR NOT FOUND" has "ShellCommand ANCHOR NOT FOUND"
    check f "anchor $i: ShellCommand byte-identical" same "$S" "$FIX/shl_drift$i"
    check f "anchor $i: AMS is left patched (written first, pinned as is)" same "$A" "$FIX/ams_fresh"
    A2=$(snap "$A"); S2=$(snap "$S")
    runp "$t"
    check f "anchor $i re-run: exit 2 again" rc_is 2
    check f "anchor $i re-run: AMS already patched" has "AccountManagerService already patched"
    check f "anchor $i re-run: both files byte-identical" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ "$A" "$A2" "$S" "$S2"
  done
  # (g) a file missing
  t=$(mktree - shl_pristine); S="$t/$SHL_REL"
  runp "$t"
  check g "AMS absent: exit 1" rc_is 1
  check g "AMS absent: output says MISSING" has MISSING
  check g "AMS absent: ShellCommand byte-identical" same "$S" "$FIX/shl_pristine"
  t=$(mktree ams_pristine -); A="$t/$AMS_REL"
  runp "$t"
  check g "ShellCommand absent: exit 1" rc_is 1
  check g "ShellCommand absent: output says MISSING" has MISSING
  check g "ShellCommand absent: AMS byte-identical" same "$A" "$FIX/ams_pristine"
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
s = open(src, encoding="utf-8").read()
if s.count(old) != 1 or old == new:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  then echo "  FAIL  mutant did not apply: $id"; LOST=$((LOST + 1)); return; fi
  cmp -s "$SCRIPT0" "$m" && { echo "  FAIL  mutant $id changed nothing"; LOST=$((LOST + 1)); return; }
  SCRIPT="$m"; run_checks
  if [[ $OUT_ALL == *"  FAIL  ($case_)"* ]]; then echo "  ok    convicted: $id by ($case_)"
  else echo "  FAIL  NOT convicted: $id (expected a failure in ($case_))"; printf '%s' "$OUT_ALL"; LOST=$((LOST + 1)); fi
  rm -f "$m"
}
echo "== mutants"
mutant R1 b "if 'pre-strip removed ' in s:" "if 'pre-strip REMOVED ' in s:"
mutant R2 c "if SIG in s:" "if False:"
mutant R3 d 'could not brace-match reloadUserAccounts (upstream changed?) -- aborting"); sys.exit(2)' 'could not brace-match reloadUserAccounts (upstream changed?) -- aborting"); sys.exit(0)'
mutant R4 f 'ShellCommand ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)' 'ShellCommand ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(0)'
[ "$LOST" = 0 ] || { echo "== $LOST mutant(s) not convicted"; exit 1; }
echo "== every mutant convicted"
