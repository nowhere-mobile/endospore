#!/usr/bin/env bash
# NWP-20261106-02: the gate and the Profile screen absorb a rotation, uiMode, keyboard or SIM change instead of
# being recreated (neither saves state; a recreation loses the one-time recovery code). Reads the manifest only.
# --mutate runs each mutant on a copy under $W and requires the suite to FAIL.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
MANIFEST="$HERE/AndroidManifest.xml"

check() { # check <manifest>
python3 -I - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
A = "{http://schemas.android.com/apk/res/android}"
root = ET.parse(sys.argv[1]).getroot()
acts = {a.get(A + "name"): a for a in root.iter("activity")}
TEN = "orientation screenSize smallestScreenSize screenLayout uiMode keyboard keyboardHidden navigation mcc mnc".split()
def flags(n):
    v = acts[n].get(A + "configChanges") or ""
    return set(f for f in v.split("|") if f)
bad = 0
def say(ok, msg):
    global bad
    print(("ok   " if ok else "FAIL ") + msg)
    bad += (not ok)
have = ".ChooserActivity" in acts and ".ProfileActivity" in acts
say(have, "C: ChooserActivity and ProfileActivity are both declared")
if have:
    c, p = flags(".ChooserActivity"), flags(".ProfileActivity")
    miss = [f for f in TEN + ["assetsPaths", "locale", "layoutDirection"] if f not in c]
    say(not miss, "M1: ChooserActivity absorbs the ten flags and keeps its three (missing: %s)" % ",".join(miss))
    miss = [f for f in TEN if f not in p]
    say(not miss, "M2: ProfileActivity absorbs the ten flags (missing: %s)" % ",".join(miss))
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" != "--mutate" ]; then
  check "$MANIFEST"; exit $?
fi

rc=0
mutant() { # mutant <name> <python expr on s>
  local name=$1 expr=$2 f out
  f=$(mktemp -p "$W")
  python3 -I - "$MANIFEST" "$f" "$expr" <<'PY' || { echo "FAIL mutant $name did not apply"; rc=1; return; }
import sys, re
s = open(sys.argv[1]).read()
n = eval(sys.argv[3])
if n == s: sys.exit(1)
open(sys.argv[2], "w").write(n)
PY
  out=$(check "$f")
  if [ $? -eq 0 ]; then echo "FAIL mutant $name survived"; rc=1; else echo "ok   mutant $name convicted"; fi
}
mutant drop-mcc-profile 're.sub(r"(\.ProfileActivity.*?configChanges=\"[^\"]*?)\|mcc", r"\1", s, count=1, flags=re.S)'
mutant drop-keyboardHidden-chooser 're.sub(r"(\.ChooserActivity.*?configChanges=\"[^\"]*?)\|keyboardHidden", r"\1", s, count=1, flags=re.S)'
# keyboard is the one flag inside another flag's name: only the whole-flag compare sees it gone beside keyboardHidden.
mutant drop-keyboard-profile 're.sub(r"(\.ProfileActivity.*?configChanges=\"[^\"]*?)\|keyboard(?=\|)", r"\1", s, count=1, flags=re.S)'
mutant drop-assetsPaths 's.replace("assetsPaths|locale|layoutDirection|orientation","locale|layoutDirection|orientation",1)'
mutant drop-profile-attr 're.sub(r"(\.ProfileActivity.*?)\n\s*android:configChanges=\"[^\"]*\"", r"\1", s, count=1, flags=re.S)'
mutant rename-profile 's.replace("android:name=\".ProfileActivity\"","android:name=\".ProfileActivityX\"",1)'
exit $rc
