#!/usr/bin/env bash
# run.sh <chooser dir> <fixture> [<sed script> [<work dir>]] -- NWP-20261022-11: run TelWireCases against the chooser's real
# TelArrival (telRequest, the arrival ids, parse, untilAnswered) under plain javac/java, and against the fixture the
# daemon's Go test reads too (core/agent/testdata/tel-wire-v2.txt). core/vendor-common/bin/test-tel-wire-java.sh
# resolves the JDK and is what CI runs.
#
# The members are LIFTED BY NAME from TelArrival.java into one class and EXECUTED; a name that is missing, or found
# twice, stops the run (exit 2, EXTRACTION FAILED) rather than a stale copy passing. android.util.Base64,
# android.os.SystemClock and DaemonSocket are the stand-ins under stubs/. The optional sed script is applied to the
# LIFTED copy (never to the source): --mutate's mutants.
#
# JAVAC and JAVA name the tools (default: javac, java on PATH). Exit status: 0 every case passed; 1 a case failed;
# 2 cannot run (a tool, a file, the fixture or a member missing); 3 the lifted class does not compile; 4 the sed script
# changed nothing.
#
# The work dir, when given, is a fresh directory INSIDE the caller's own trapped root (test-tel-wire-java.sh passes one per
# baseline and per mutant): run.sh then makes no root of its own and leaves the cleanup to that caller. Without one it
# makes and traps its own, so a hand run still leaves nothing behind.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir> <fixture> [<sed script> [<work dir>]]}"
FIX="${2:?usage: run.sh <core/chooser dir> <fixture> [<sed script> [<work dir>]]}"
SEDS="${3:-}"
WORK="${4:-}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
SRC="$CH/src/com/nowhere/chooser/TelArrival.java"
for f in "$SRC" "$FIX" "$here/TelWireCases.java" "$here/stubs/DaemonSocket.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
if [ -n "$WORK" ]; then
  W=$WORK; mkdir -p "$W" || exit 2
else
  W=$(mktemp -d) || exit 2
  trap 'rm -rf "$W"' EXIT
fi

methods="backoffMs stamp smsId callId mmsId sha256Hex telRequest b64 parse untilAnswered rememberDial knownPrivate"
mkdir -p "$W/src" "$W/classes"
{
  cat <<'HDR'
import android.os.SystemClock;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

final class TelArrival {
HDR
  # the nested class and the DIALS field: from the declaration to the brace closing it (a one-line field ends on itself)
  awk '
    !on && /^[ \t]*static final class Reply / { on=1; depth=0 }
    on { print; depth+=gsub(/\{/,"{")-gsub(/\}/,"}"); if (depth==0) on=0 }
  ' "$SRC"
  grep -E '^[ \t]*private static final [^=]* DIALS = [^;]*;' "$SRC" | sed -E 's/^([ \t]*)private /\1/'
  for m in $methods; do
    # from the declaration (optional modifier, then 'static' -- never a call site) to the brace closing it
    awk -v m="$m" '
      !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "\\(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) on=0 }
    ' "$SRC" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
  done
  echo "}"
} > "$W/src/TelArrival.java"
bad=0
for m in $methods; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m\(" "$W/src/TelArrival.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: EXTRACTION FAILED: $m found $n time(s), want 1" >&2; bad=1; }
done
n=$(grep -cE '^[ \t]*static final class Reply ' "$W/src/TelArrival.java" || true)
[ "$n" = 1 ] || { echo "run.sh: EXTRACTION FAILED: Reply found $n time(s), want 1" >&2; bad=1; }
n=$(grep -cE '^[ \t]*static final [^=]* DIALS = ' "$W/src/TelArrival.java" || true)
[ "$n" = 1 ] || { echo "run.sh: EXTRACTION FAILED: DIALS found $n time(s), want 1" >&2; bad=1; }
[ "$bad" = 0 ] || exit 2

if [ -n "$SEDS" ]; then
  cp "$W/src/TelArrival.java" "$W/orig.java"
  sed -i "$SEDS" "$W/src/TelArrival.java" || exit 4
  if cmp -s "$W/orig.java" "$W/src/TelArrival.java"; then echo "run.sh: the sed script changed nothing" >&2; exit 4; fi
fi

cp "$here/TelWireCases.java" "$W/src/"
srcs=$(find "$here/stubs" -name '*.java')
# shellcheck disable=SC2086
"$JAVAC" -encoding UTF-8 -d "$W/classes" "$W/src/TelArrival.java" "$W/src/TelWireCases.java" $srcs \
  || { echo "run.sh: the lifted class does not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$W/classes" TelWireCases "$FIX"
