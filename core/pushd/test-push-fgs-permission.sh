#!/usr/bin/env bash
# test-push-fgs-permission.sh [--mutate] -- NWP-20261203-12: NowherePush may start its push service from the background.
# DistributorReceiver.onReceive calls PushService.enqueueRegister / enqueueUnregister, and startFg calls
# ctx.startForegroundService from the receiver, i.e. from the background. Android 12+ refuses that start
# (ForegroundServiceStartNotAllowedException, device-proof S6) unless the caller holds
# android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND (protectionLevel signature|privileged|...). NowherePush is
# signed with the platform key (Android.bp certificate "platform"), so the signature half grants it. A system app's
# manifest is re-scanned on a reflash with a pinned build fingerprint only when its versionCode rises, so the bump is
# pinned too. Source-level: python3 xml.etree reads the manifest, a brace-matched scan reads the Android.bp block.
#
# Cases: (a) the manifest's package is com.nowhere.push and it requests START_FOREGROUND_SERVICES_FROM_BACKGROUND as a
# uses-permission element (exact name; ElementTree drops comments, so a commented-out line does not count);
# (b) versionCode is an integer > 2; (c) the android_app block named NowherePush has certificate: "platform" and
# manifest: "pushd/AndroidManifest.xml"; (d) PushService is declared with foregroundServiceType specialUse and
# FOREGROUND_SERVICE + FOREGROUND_SERVICE_SPECIAL_USE are requested.
# On origin/main the plain run FAILs (a) and (b).
#
#   bash test-push-fgs-permission.sh            # the cases
#   bash test-push-fgs-permission.sh --mutate   # ... plus mutants M1-M7 that must each be CONVICTED by their named case
# PUSH_MANIFEST and PUSH_BP override the AndroidManifest.xml and Android.bp under test.
# Exit: 0 pass, 1 a case failed or a mutant survived or did not apply, 2 cannot run (no python3).
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MANIFEST=${PUSH_MANIFEST:-$ROOT/core/pushd/AndroidManifest.xml}
BP=${PUSH_BP:-$ROOT/core/vendor-common/Android.bp}
if ! command -v python3 >/dev/null 2>&1; then
  echo "test-push-fgs-permission: FAIL -- no python3 on PATH; this suite did NOT run" >&2
  exit 2
fi
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

CHECK=$(mktemp -p "$W" check.XXXXXX.py)
cat >"$CHECK" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
A = '{http://schemas.android.com/apk/res/android}'
manifest_path, bp_path = sys.argv[1], sys.argv[2]
bad = False
def res(case, ok, msg):
    global bad
    print(('PASS' if ok else 'FAIL') + ' (' + case + ') ' + msg)
    if not ok:
        bad = True
try:
    root = ET.parse(manifest_path).getroot()
except Exception as e:
    root = None
    err = 'manifest does not parse: %s' % e
if root is None:
    for c in ('a', 'b', 'd'):
        res(c, False, err)
else:
    perms = [p.get(A + 'name') for p in root.findall('uses-permission')]
    pkg = root.get('package')
    want = 'android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND'
    res('a', pkg == 'com.nowhere.push' and want in perms,
        'package %r requests %s: %s' % (pkg, want, want in perms))
    vc = root.get(A + 'versionCode')
    try:
        ok = int(vc) > 2
    except (TypeError, ValueError):
        ok = False
    res('b', ok, 'versionCode %r is an integer > 2' % vc)
    svc = [s for s in root.findall('application/service')
           if s.get(A + 'name') in ('.PushService', 'com.nowhere.push.PushService')]
    types = set((svc[0].get(A + 'foregroundServiceType') or '').split('|')) if svc else set()
    fg = 'android.permission.FOREGROUND_SERVICE' in perms
    su = 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE' in perms
    res('d', bool(svc) and 'specialUse' in types and fg and su,
        'PushService declared %s, specialUse type %s, FOREGROUND_SERVICE %s, FOREGROUND_SERVICE_SPECIAL_USE %s'
        % (bool(svc), 'specialUse' in types, fg, su))
try:
    bp = open(bp_path, encoding='utf-8').read()
except Exception as e:
    bp = None
    res('c', False, 'Android.bp does not read: %s' % e)
if bp is not None:
    block = None
    for m in re.finditer(r'(?m)^android_app\s*\{', bp):
        depth, i = 0, m.end() - 1
        while i < len(bp):
            if bp[i] == '{':
                depth += 1
            elif bp[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = bp[m.end():i]
        if re.search(r'(?m)^\s*name:\s*"NowherePush"\s*,', body):
            block = body
            break
    if block is None:
        res('c', False, 'no android_app block named NowherePush in Android.bp')
    else:
        cert = re.search(r'(?m)^\s*certificate:\s*"platform"\s*,', block) is not None
        man = re.search(r'(?m)^\s*manifest:\s*"pushd/AndroidManifest\.xml"\s*,', block) is not None
        res('c', cert and man, 'NowherePush block: certificate "platform" %s, manifest "pushd/AndroidManifest.xml" %s'
            % (cert, man))
sys.exit(1 if bad else 0)
PY

check() { python3 -I "$CHECK" "$1" "$2"; }

out=$(check "$MANIFEST" "$BP"); rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
  echo "test-push-fgs-permission: FAIL (plain run)"
  exit 1
fi
echo "test-push-fgs-permission: PASS (plain run)"
[ "$MUTATE" = yes ] || exit 0

# Edits only the android_app block named NowherePush: other modules also say certificate: "platform".
BPEDIT=$(mktemp -p "$W" bpedit.XXXXXX.py)
cat >"$BPEDIT" <<'PY'
import re, sys
old, new, path = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
for m in re.finditer(r'(?m)^android_app\s*\{', s):
    depth, i = 0, m.end() - 1
    while i < len(s):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1
    if re.search(r'(?m)^\s*name:\s*"NowherePush"\s*,', s[m.end():i]):
        s = s[:m.end()] + s[m.end():i].replace(old, new) + s[i:]
        break
open(path, 'w', encoding='utf-8').write(s)
PY

# mutant ID CASE FILE(manifest|bp) EDIT...: EDIT runs on a copy inside $W; an unchanged copy is a failure.
convicted=0; total=0; failed=0
mutant() {
  local id=$1 case=$2 which=$3; shift 3
  local orig copy mout
  total=$((total + 1))
  if [ "$which" = manifest ]; then orig=$MANIFEST; else orig=$BP; fi
  copy=$(mktemp -p "$W" "mut-$id.XXXXXX")
  cp "$orig" "$copy"
  "$@" "$copy"
  if cmp -s "$orig" "$copy"; then
    echo "MUTANT $id DID NOT APPLY"; failed=1; return
  fi
  if [ "$which" = manifest ]; then mout=$(check "$copy" "$BP"); else mout=$(check "$MANIFEST" "$copy"); fi
  case $'\n'"$mout" in
    *$'\n'"FAIL ($case)"*) echo "MUTANT $id CONVICTED by ($case)"; convicted=$((convicted + 1)) ;;
    *) echo "MUTANT $id SURVIVED (expected FAIL ($case))"; printf '%s\n' "$mout" | sed 's/^/  /'; failed=1 ;;
  esac
}
P='android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND'
mutant M1 a manifest sed -i "/\"$P\"/d"
mutant M2 a manifest sed -i 's/START_FOREGROUND_SERVICES_FROM_BACKGROUND/START_FOREGROUND_SERVICE_FROM_BACKGROUND/'
mutant M3 a manifest sed -i "s|^\( *\)\(<uses-permission android:name=\"$P\"/>\)|\1<!-- \2 -->|"
mutant M4 b manifest sed -i 's/android:versionCode="[0-9]*"/android:versionCode="2"/'
mutant M5 c bp python3 -I "$BPEDIT" 'certificate: "platform"' 'certificate: "presigned"'
mutant M6 c bp python3 -I "$BPEDIT" 'manifest: "pushd/AndroidManifest.xml"' 'manifest: "pushd/Manifest.xml"'
mutant M7 d manifest sed -i '/"android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/d'
echo "$convicted of $total mutants convicted"
if [ "$failed" -ne 0 ] || [ "$convicted" -ne "$total" ]; then
  echo "test-push-fgs-permission: FAIL (--mutate)"
  exit 1
fi
echo "test-push-fgs-permission: PASS (--mutate)"
