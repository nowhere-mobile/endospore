#!/usr/bin/env bash
# run.sh <StoreInstaller.java> <StoreService.java> <napps StoreActivity.java> -- NWP-20261105-03: lift keepAutoImpl verbatim
# (by signature, brace depth) into a harness StoreInstaller and getAppReply into a harness StoreService, stub what they
# call (writeAtomic and clearTurnedOff throw on demand, noteAppSeen, APPKEEP_LOCK, ProfileActivity, Context, Log), run
# KeepWriteFailCases, then source-check that nApps' OK-UNSAVED and OK-OFF branches come before the generic OK branch and
# (NWP-20261129-38) that getApp reads the Off nApps default before keepAuto and passes it, with no keep line, to getAppReply.
# $JAVAC / $JAVA / KEEP_WRITE_FAIL_TMP come from core/chooser/test-keep-write-fail-java.sh.
# getAppReply is OPTIONAL: when StoreService does not name it at all, it is stubbed to return null, so its eight cases
# fail and the keepAutoImpl cases still run. A StoreService with the older three-parameter form exits 2.
# Exit codes: 1 = a case or source check failed; 2 = keepAutoImpl or getApp did not extract, or StoreService names
# getAppReply but it did not extract by its signature; 3 = compile failure or JVM died with anything but 0/1.
set -euo pipefail
SI="${1:?usage: run.sh StoreInstaller.java StoreService.java StoreActivity.java}"
SS="${2:?}"
SA="${3:?}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
export PYTHONIOENCODING=utf-8
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${KEEP_WRITE_FAIL_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

lift() { # lift <file> <signature>: print the member, exit 2 unless it matches exactly once
  python3 -I - "$1" "$2" <<'PY'
import io, sys
path, arg = sys.argv[1:3]
src = io.open(path, encoding='utf-8').read()
def fail(msg):
    sys.stderr.write('EXTRACTION FAILED: ' + msg + '\n'); sys.exit(2)
if src.count(arg) != 1:
    fail('%d matches of %s' % (src.count(arg), arg))
i = src.index(arg)
k = src.index('{', i)
depth = 0; end = len(src)
while k < end:
    c = src[k]
    if c == '"':
        k += 1
        while k < end and src[k] != '"':
            k += 2 if src[k] == '\\' else 1
    elif c == "'":
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

KEEP=$(lift "$SI" 'private static boolean keepAutoImpl(Context ctx, String pkg, boolean overPlan, String mode) {') \
  || { echo "EXTRACTION FAILED: keepAutoImpl" >&2; exit 2; }
REPLY_SIG='static String getAppReply(boolean kept, boolean overPlan, boolean notKeptByDefault, String pkg) {'
if grep -qF 'getAppReply' "$SS"; then
  REPLY=$(lift "$SS" "$REPLY_SIG") || { echo "EXTRACTION FAILED: getAppReply" >&2; exit 2; }
else
  # No getAppReply at all. Stub it to return null so its cases FAIL and the keepAutoImpl cases still run.
  echo "  NOTE  no getAppReply in $SS -- stubbed to return null, so its eight cases fail"
  REPLY="$REPLY_SIG return null; }"
fi
[ -n "$KEEP" ] && [ -n "$REPLY" ] || { echo "EXTRACTION FAILED: empty member" >&2; exit 2; }

mkdir -p "$D/src/com/nowhere/chooser" "$D/src/android/content" "$D/src/android/util" "$D/out"
cat > "$D/src/android/content/Context.java" <<'J'
package android.content;
public class Context {
  private final java.io.File dir;
  public Context(java.io.File dir) { this.dir = dir; }
  public java.io.File getFilesDir() { return dir; }
}
J
cat > "$D/src/android/util/Log.java" <<'J'
package android.util;
public class Log {
  public static int w(String tag, String msg, Throwable t) { return 0; }
}
J
cat > "$D/src/com/nowhere/chooser/ProfileActivity.java" <<'J'
package com.nowhere.chooser;
final class ProfileActivity {
  static final String APPDEF_OFF = "off";
  static void recordPlayDepAtInstall(android.content.Context ctx, String pkg) {}
}
J
{
  echo 'package com.nowhere.chooser;'
  echo 'import android.content.Context;'
  echo 'import android.util.Log;'
  echo 'import java.io.File;'
  echo 'final class StoreInstaller {'
  echo '  static final Object APPKEEP_LOCK = new Object();'
  echo '  static boolean failWrite, failClear;'
  echo '  static int writes;'
  echo '  static void reset() { failWrite = false; failClear = false; writes = 0; }'
  echo '  static void writeAtomic(File f, String content) throws java.io.IOException {'
  echo '    if (failWrite) throw new java.io.IOException("ENOSPC");'
  echo '    writes++;'
  echo '    java.nio.file.Files.write(f.toPath(), content.getBytes(java.nio.charset.StandardCharsets.UTF_8));'
  echo '  }'
  echo '  static void clearTurnedOff(Context ctx, java.util.Collection<String> pkgs) {'
  echo '    if (failClear) throw new RuntimeException("clearTurnedOff");'
  echo '  }'
  echo '  static void noteAppSeen(Context ctx, String pkg) {}'
  printf '%s\n' "${KEEP/private static boolean/static boolean}"
  echo '}'
} > "$D/src/com/nowhere/chooser/StoreInstaller.java"
{
  echo 'package com.nowhere.chooser;'
  echo 'final class StoreService {'
  printf '%s\n' "$REPLY"
  echo '}'
} > "$D/src/com/nowhere/chooser/StoreService.java"

"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$D/src" -name '*.java') "$here/KeepWriteFailCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.KeepWriteFailCases "$D" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# The napps source: each specific branch must come before the generic OK branch (startsWith("OK") also matches it).
for word in OK-UNSAVED OK-OFF; do
  order=$(python3 -I - "$SA" "$word" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding='utf-8').read()
b = 'r.startsWith("%s")' % sys.argv[2]
u = s.find(b); g = s.find('r.startsWith("OK"))')
print('ok' if u >= 0 and g >= 0 and s.count(b) == 1 and u < g else 'bad')
PY
  )
  if [ "$order" = ok ]; then echo "  ok    napps $word branch comes before the generic OK branch"
  else echo "  FAIL  napps $word branch missing, repeated or after the generic OK branch"; rc=1; fi
done

# The getApp source (NWP-20261129-38): the Off default is read before keepAuto, and only an app with no keep line gets
# the flag. getApp talks to the daemon and the installer, so its tail is checked as text and not run.
GETAPP=$(lift "$SS" 'public String getApp(String pkg, String label) {') \
  || { echo "EXTRACTION FAILED: getApp" >&2; exit 2; }
wired=$(GETAPP_BODY="$GETAPP" python3 -I - <<'PY'
import os
s = os.environ['GETAPP_BODY']
want = ['boolean offDefault = ProfileActivity.APPDEF_OFF.equals(ProfileActivity.cfgStatic(StoreService.this, ProfileActivity.CFG_APPS_NAPPS));',
        'StoreInstaller.keepAuto(StoreService.this, pkg, overPlan)',
        'return getAppReply(kept, overPlan, offDefault && !StoreInstaller.keepSetHas(StoreService.this, pkg), pkg);']
at = [s.find(w) for w in want]
print('ok' if all(s.count(w) == 1 for w in want) and at == sorted(at) else 'bad')
PY
)
if [ "$wired" = ok ]; then echo "  ok    getApp reads the Off default before keepAuto and passes it with no keep line"
else echo "  FAIL  getApp does not read the Off default before keepAuto, or does not pass it with no keep line"; rc=1; fi
exit "$rc"
