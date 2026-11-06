#!/usr/bin/env bash
# run.sh <AppInstallReceiver.java> <ProfileActivity.java> -- NWP-20261021-09: lift AppInstallReceiver.decide verbatim by
# signature (`private` stripped) into a harness class AppInstallReceiver, and ProfileActivity.cfgKeyForInstaller plus the
# constants it and decide read (CFG_APPS_NAPPS/PLAY/AURORA/GOS/OTHER, GOS_STORE_PKG, APPDEF_OFF) into a stub
# ProfileActivity (tests/install-default/ProfileActivityStub.java.in, spliced at its marker), so the REAL installer-to-bucket
# mapping runs too. Everything else decide asks is a stub: ProfileActivity.appDefaultForInstaller / isBundledSystem /
# explicitlyTurnedOff answer per case and count their calls, StoreInstaller journals every call in order, and tiny
# android.* stubs (stubs/) supply Context, PackageManager, InstallSourceInfo, Build.VERSION.SDK_INT and a capturing
# util.Log. InstallDefaultCases then runs. $JAVAC / $JAVA come from the caller (core/chooser/test-install-default-java.sh).
#
# Exit codes: 1 = a case failed; 2 = a member did not extract (anchor moved, matched != once, braces unbalanced);
# 3 = the lifted classes or the cases did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
AIR="${1:?usage: run.sh AppInstallReceiver.java ProfileActivity.java}"
PA="${2:?usage: run.sh AppInstallReceiver.java ProfileActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
export PYTHONIOENCODING=utf-8
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${INSTALL_DEFAULT_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

lift() { # lift method|const <file> <signature-or-NAME>: print the member, exit 2 unless it matches exactly once
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, re, sys
mode, path, arg = sys.argv[1:4]
src = io.open(path, encoding='utf-8').read()

def fail(msg):
    sys.stderr.write('EXTRACTION FAILED: ' + msg + '\n'); sys.exit(2)

if mode == 'const':
    pat = re.compile(r'^[ \t]*(static final String ' + re.escape(arg) + r'\s*=.*)$', re.M)
    m = pat.findall(src)
    if len(m) != 1:
        fail('%d matches of constant %s' % (len(m), arg))
    print(m[0].strip()); sys.exit(0)

n = src.count(arg)
if n != 1:
    fail('%d matches of %s' % (n, arg))
i = src.index(arg)
j = src.index('{', i)
depth = 0; k = j; end = len(src)
while k < end:
    c = src[k]
    if c == '"':                       # string literal, with escapes
        k += 1
        while k < end and src[k] != '"':
            k += 2 if src[k] == '\\' else 1
    elif c == "'":                     # char literal
        k += 1
        while k < end and src[k] != "'":
            k += 2 if src[k] == '\\' else 1
    elif src.startswith('//', k):
        k = src.find('\n', k)
        if k < 0: break
    elif src.startswith('/*', k):
        k = src.find('*/', k + 2)
        if k < 0: break
        k += 1
    elif c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k + 1]); sys.exit(0)
    k += 1
fail('unbalanced braces in ' + arg)
PY
}

DECIDE=$(lift method "$AIR" 'private static boolean decide(Context ctx, String pkg, boolean replacing, String via) {') \
  || { echo "EXTRACTION FAILED: decide" >&2; exit 2; }
CFGKEY=$(lift method "$PA" 'static String cfgKeyForInstaller(String installer) {') \
  || { echo "EXTRACTION FAILED: cfgKeyForInstaller" >&2; exit 2; }
[ -n "$DECIDE" ] && [ -n "$CFGKEY" ] || { echo "EXTRACTION FAILED: empty member" >&2; exit 2; }
CONSTS=""
for k in CFG_APPS_NAPPS CFG_APPS_PLAY CFG_APPS_AURORA CFG_APPS_GOS GOS_STORE_PKG CFG_APPS_OTHER APPDEF_OFF; do
  c=$(lift const "$PA" "$k") || { echo "EXTRACTION FAILED: $k" >&2; exit 2; }
  [ -n "$c" ] || { echo "EXTRACTION FAILED: $k" >&2; exit 2; }
  CONSTS+="  $c"$'\n'
done

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
# NWP-20261122-06: decide asks PlayChoice (pure java) for a Play stack member's keep-mode; it compiles as-is.
PLAY="${PLAY_CHOICE_SRC:-$(dirname "$PA")/PlayChoice.java}"
[ -f "$PLAY" ] || { echo "EXTRACTION FAILED: no $PLAY" >&2; exit 2; }
cp "$PLAY" "$D/src/com/nowhere/chooser/PlayChoice.java"
{
  echo 'package com.nowhere.chooser;'
  echo 'import android.content.Context;'
  echo 'final class AppInstallReceiver {'
  printf '%s\n' "${DECIDE#private }"
  echo '}'
} > "$D/src/com/nowhere/chooser/AppInstallReceiver.java"
LIFTED="$CONSTS
$CFGKEY" python3 -I - "$here/ProfileActivityStub.java.in" "$D/src/com/nowhere/chooser/ProfileActivity.java" <<'PY'
import io, os, sys
tpl = io.open(sys.argv[1], encoding='utf-8').read()
marker = '// @@LIFTED@@'
if tpl.count(marker) != 1:
    sys.stderr.write('EXTRACTION FAILED: stub marker\n'); sys.exit(2)
io.open(sys.argv[2], 'w', encoding='utf-8').write(tpl.replace(marker, os.environ['LIFTED']))
PY

"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') \
    "$D/src/com/nowhere/chooser/"*.java "$here/InstallDefaultCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.InstallDefaultCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
