#!/usr/bin/env bash
# test-usb-debug-refusal-copy.sh -- NWP-20261208-27.
#
# When an unauthorized computer asks for USB debugging while a profile is in front, AOSP SystemUI's
# UsbDebuggingSecondaryUserActivity tells the non-admin user to "switch to an admin user". Nowhere has no user
# switcher: the only admin is user 0, reached as owner mode. Both editions overlay SystemUI's
# usb_debugging_secondary_user_message with the words Chester approved on 2026-11-17 (NWP-20261116-48); the
# title stays stock. This grep suite pins the words and the wiring:
#   C1  each edition's strings.xml holds exactly one <string>, usb_debugging_secondary_user_message, whose text
#       (after aapt2 unescaping) is the approved message byte for byte, every apostrophe escaped
#   C2  neither file overrides usb_debugging_secondary_user_title, nor any other resource
#   C3  Endospore: the manifest targets com.android.systemui (static, no code, com.nowhere.overlay.systemui) and
#       Android.bp is a platform-signed, product runtime_resource_overlay named NowhereSystemUIOverlay
#   C4  endospore.mk installs NowhereSystemUIOverlay (uncommented), keeps NowhereFrameworkOverlay, and points no
#       PRODUCT_PACKAGE_OVERLAYS line at the rro dir
#   C5  Diaspore: the file sits under the staged static overlay at values/, and diaspore.mk still applies it
#
# Usage: test-usb-debug-refusal-copy.sh [--mutate]
#   --mutate  also runs M1-M9 against copies of the files; each must be CONVICTED by its named assertion.
set -uo pipefail

MUTATE=0
for a in "$@"; do
    case "$a" in
        --mutate) MUTATE=1 ;;
        *) echo "usage: $0 [--mutate]" >&2; exit 2 ;;
    esac
done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not found" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/../../.." && pwd)

# The approved message, held once. Passed to python through the environment.
MSG="The profile signed in now can't turn on USB debugging. Only this phone's owner can, in owner mode."
export MSG

ENDO_RRO=editions/endospore/vendor/rro/NowhereSystemUIOverlay
ENDO_BP=$ENDO_RRO/Android.bp
ENDO_MAN=$ENDO_RRO/AndroidManifest.xml
ENDO_STR=$ENDO_RRO/res/values/strings.xml
ENDO_MK=editions/endospore/endospore.mk
DIA_STR=editions/diaspore/vendor/overlay/frameworks/base/packages/SystemUI/res/values/strings.xml
DIA_MK=editions/diaspore/diaspore.mk
FILES="$ENDO_BP $ENDO_MAN $ENDO_STR $ENDO_MK $DIA_STR $DIA_MK"
export ENDO_BP ENDO_MAN ENDO_STR ENDO_MK DIA_STR DIA_MK

# check <root>: one line per assertion; returns 0 only when every assertion passes.
check() {
    python3 -I - "$1" <<'PY'
import os, re, sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
msg = os.environ["MSG"]
env = os.environ
A = "{http://schemas.android.com/apk/res/android}"
fails = 0

def report(cid, problems):
    global fails
    if problems:
        fails += 1
        for p in problems:
            print(f"{cid} FAIL {p}")
    else:
        print(f"{cid} PASS")

def read(rel):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as f:
        return f.read()

def parse(rel):
    text = read(rel)
    if text is None:
        return None, f"{rel}: missing"
    try:
        return ET.fromstring(text), None
    except ET.ParseError as e:
        return None, f"{rel}: not XML ({e})"

strs = [env["ENDO_STR"], env["DIA_STR"]]

# C1: the one message string, byte for byte, every apostrophe escaped.
p = []
for rel in strs:
    tree, err = parse(rel)
    if err:
        p.append(err)
        continue
    if tree.tag != "resources":
        p.append(f"{rel}: root is <{tree.tag}>, not <resources>")
    els = tree.findall("string")
    if len(els) != 1:
        p.append(f"{rel}: {len(els)} <string> elements, want 1")
        continue
    el = els[0]
    if el.get("name") != "usb_debugging_secondary_user_message":
        p.append(f"{rel}: string named {el.get('name')!r}")
    raw = el.text or ""
    if re.search(r"(?<!\\)'", raw):
        p.append(f"{rel}: an apostrophe is not escaped for aapt2")
    if raw.replace("\\'", "'") != msg:
        p.append(f"{rel}: text {raw!r} is not the approved message")
report("C1", p)

# C2: the title stays stock, and nothing else is overlaid.
p = []
for rel in strs:
    tree, err = parse(rel)
    if err:
        p.append(err)
        continue
    if any(e.get("name") == "usb_debugging_secondary_user_title" for e in tree.iter()):
        p.append(f"{rel}: overrides usb_debugging_secondary_user_title")
    kids = list(tree)
    if len(kids) != 1:
        p.append(f"{rel}: {len(kids)} resources, want 1")
report("C2", p)

# C3: the Endospore manifest and module.
p = []
man, err = parse(env["ENDO_MAN"])
if err:
    p.append(err)
else:
    if man.get("package") != "com.nowhere.overlay.systemui":
        p.append(f"manifest package {man.get('package')!r}")
    ov = man.findall("overlay")
    if len(ov) != 1:
        p.append(f"{len(ov)} <overlay> elements, want 1")
    else:
        if ov[0].get(A + "targetPackage") != "com.android.systemui":
            p.append(f"targetPackage {ov[0].get(A + 'targetPackage')!r}")
        if ov[0].get(A + "isStatic") != "true":
            p.append(f"isStatic {ov[0].get(A + 'isStatic')!r}")
    app = man.findall("application")
    if len(app) != 1 or app[0].get(A + "hasCode") != "false":
        p.append("no <application android:hasCode=\"false\">")
bp = read(env["ENDO_BP"])
if bp is None:
    p.append(f"{env['ENDO_BP']}: missing")
else:
    bp = re.sub(r"//[^\n]*", "", bp)
    blocks = re.findall(r"runtime_resource_overlay\s*\{([^}]*)\}", bp)
    if len(blocks) != 1:
        p.append(f"{len(blocks)} runtime_resource_overlay blocks, want 1")
    else:
        body = blocks[0]
        for want in (r'name:\s*"NowhereSystemUIOverlay"\s*,', r"product_specific:\s*true\s*,",
                     r'certificate:\s*"platform"\s*,'):
            if not re.search(want, body):
                p.append(f"Android.bp lacks {want}")
report("C3", p)

def mk_lines(rel):
    text = read(rel)
    return None if text is None else text.splitlines()

# C4: endospore.mk installs the module.
p = []
lines = mk_lines(env["ENDO_MK"])
if lines is None:
    p.append(f"{env['ENDO_MK']}: missing")
else:
    if not any(re.fullmatch(r"\s*PRODUCT_PACKAGES\s*\+=\s*NowhereSystemUIOverlay\s*", l) for l in lines):
        p.append("no uncommented PRODUCT_PACKAGES += NowhereSystemUIOverlay")
    if not any(re.fullmatch(r"\s*PRODUCT_PACKAGES\s*\+=\s*NowhereFrameworkOverlay\s*", l) for l in lines):
        p.append("PRODUCT_PACKAGES += NowhereFrameworkOverlay is gone")
    for l in lines:
        s = l.split("#", 1)[0]
        if "PRODUCT_PACKAGE_OVERLAYS" in s and "rro" in s:
            p.append(f"a static overlay line points at the rro dir: {l.strip()!r}")
report("C4", p)

# C5: the Diaspore file is under the staged static overlay, and diaspore.mk applies it.
p = []
if read(env["DIA_STR"]) is None:
    p.append(f"{env['DIA_STR']}: missing")
lines = mk_lines(env["DIA_MK"])
if lines is None:
    p.append(f"{env['DIA_MK']}: missing")
elif not any(re.fullmatch(r"\s*PRODUCT_PACKAGE_OVERLAYS\s*\+=\s*vendor/diaspore/overlay\s*", l) for l in lines):
    p.append("diaspore.mk lacks PRODUCT_PACKAGE_OVERLAYS += vendor/diaspore/overlay")
report("C5", p)

sys.exit(1 if fails else 0)
PY
}

out=$(check "$root")
rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then
    echo "test-usb-debug-refusal-copy: FAIL"
    exit 1
fi
echo "test-usb-debug-refusal-copy: all checks PASS"
[ "$MUTATE" -eq 1 ] || exit 0

# pyedit <file> <old> <new>: replace the first <old> with <new> in <file>.
pyedit() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    text = f.read()
with open(path, "w", encoding="utf-8") as f:
    f.write(text.replace(old, new, 1))
PY
}

# mutant <id> <want> <file> <kind> <args...>: copy the files, apply the edit, require rc 1 and a <want> FAIL line.
bad=0
total=0
mutant() {
    local id=$1 want=$2 rel=$3 kind=$4
    shift 4
    local d f mout mrc
    total=$((total + 1))
    d=$(mktemp -d -p "$W") || exit 2
    for f in $FILES; do
        if [ -f "$root/$f" ]; then
            mkdir -p "$d/$(dirname "$f")"
            cp "$root/$f" "$d/$f"
        fi
    done
    case "$kind" in
        edit)
            pyedit "$d/$rel" "$1" "$2"
            if cmp -s "$root/$rel" "$d/$rel"; then
                echo "$id NOT APPLIED"
                bad=$((bad + 1))
                return
            fi
            ;;
        delete-line)
            local tmp
            tmp=$(mktemp -p "$W") || exit 2
            grep -vF -- "$1" "$d/$rel" > "$tmp"
            cat "$tmp" > "$d/$rel"
            if cmp -s "$root/$rel" "$d/$rel"; then
                echo "$id NOT APPLIED"
                bad=$((bad + 1))
                return
            fi
            ;;
        move)
            mkdir -p "$d/$(dirname "$1")"
            mv "$d/$rel" "$d/$1"
            if [ -e "$d/$rel" ] || [ ! -f "$d/$1" ]; then
                echo "$id NOT APPLIED"
                bad=$((bad + 1))
                return
            fi
            ;;
    esac
    mout=$(check "$d")
    mrc=$?
    case "$mout" in
        "$want FAIL"*|*"
$want FAIL"*) ;;
        *) mrc=0 ;;
    esac
    if [ "$mrc" -eq 1 ]; then
        echo "$id CONVICTED by $want"
    else
        echo "$id SURVIVED (rc $mrc)"
        echo "$mout" | sed 's/^/    /'
        bad=$((bad + 1))
    fi
}

mutant M1 C1 "$ENDO_STR" edit "signed in now" "signed in"
mutant M2 C1 "$DIA_STR" edit "in owner mode." "in Owner settings."
mutant M3 C1 "$ENDO_STR" edit "can\\'t" "can't"
mutant M4 C2 "$DIA_STR" edit "</resources>" \
    "    <string name=\"usb_debugging_secondary_user_title\">USB debugging not allowed</string>
</resources>"
mutant M5 C3 "$ENDO_MAN" edit 'targetPackage="com.android.systemui"' 'targetPackage="android"'
mutant M6 C3 "$ENDO_BP" delete-line 'certificate: "platform",'
mutant M7 C4 "$ENDO_MK" edit "PRODUCT_PACKAGES += NowhereSystemUIOverlay" "# PRODUCT_PACKAGES += NowhereSystemUIOverlay"
mutant M8 C5 "$DIA_STR" move "${DIA_STR%/values/strings.xml}/values-en/strings.xml"
mutant M9 C1 "$DIA_STR" edit "owner mode." "owner mode!"

echo "$((total - bad))/$total mutants convicted"
[ "$bad" -eq 0 ] || exit 1
exit 0
