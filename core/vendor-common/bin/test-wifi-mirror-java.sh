#!/usr/bin/env bash
# test-wifi-mirror-java.sh [--mutate] -- NWP-20261015-31: the WIFI-MIRROR line format (Wi-Fi MAC mode survives to the gate,
# #631). Runs core/chooser/tests/wifi-mirror: WifiMirrorLine (the encoder WifiMirror.capture uses and the parser
# ChooserActivity.maybeMirrorWifi uses) compiled alone and EXECUTED, and the two call sites checked by text.
#
# WHY THIS IS COMMITTED. The per-network MAC-randomization mode rides as the THIRD tab field of a line. Without it a
# network the owner set to "use device MAC" rejoins at the gate with a random MAC and a MAC-allowlist AP refuses it, and
# nothing noticed when the first fix (#467) landed on a capture path that never runs. The encoder and the parser were two
# copies of one format in two files with no test; core/agent/wifi_mirror_test.go covers the daemon's verbatim storage.
#
# NWP-20261020-31: adoptRequest (the WIFI-ADOPT counts request) is executed, and maybeMirrorWifi's adopt log is pinned to
# the addNetwork id (an "adopted" line only for id >= 0) with each pass's counts sent after the loop.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE (a copy that no longer
# compiles, or whose edit does not apply, convicts nothing and is reported as a failure).
#
#   bash test-wifi-mirror-java.sh            # the cases
#   bash test-wifi-mirror-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/wifi-mirror/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-wifi-mirror-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
bash "$RUN" "$CH"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  M=$(mktemp -d)
  trap 'rm -rf "$M"' EXIT
  mutate(){ # mutate <label> <file under the chooser dir> <sed script>
    rm -rf "$M/c"; mkdir -p "$M/c/src/com/nowhere/chooser"
    cp "$CH"/src/com/nowhere/chooser/*.java "$M/c/src/com/nowhere/chooser/"
    local f="$M/c/$2"
    if ! sed -i "$3" "$f" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CH/$2"; then no "MUTATION INERT: $1"; return; fi
    bash "$RUN" "$M/c" >/dev/null 2>&1; local r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $1" ;;
    esac
  }
  L=src/com/nowhere/chooser/WifiMirrorLine.java
  mutate "the >= 0 guard dropped: the field is always appended" $L 's/if (macMode >= 0) line/if (true) line/'
  mutate "the third field is never appended"                    $L 's/if (macMode >= 0) line += "\\t" + macMode;//'
  mutate "parse ignores the third field"                        $L 's/f.length > 2 ? f\[2\].trim() : ""/""/'
  mutate "parse accepts a one-field line"                       $L 's/if (f.length < 2) return null;//'
  mutate "encode deletes every quote of the SSID again"         $L 's/String ssid = unquote(rawSsid);/String ssid = rawSsid.replace("\\"", "");/'
  mutate "parse trims the PSK again"                            $L 's/return new String\[\] {f\[0\], f\[1\],/return new String[] {f[0], f[1].trim(),/'
  mutate "encode accepts an unquoted SSID"                      $L 's/if (s.length() < 2 || !s.startsWith("\\"") || !s.endsWith("\\"")) return null;/if (s.length() < 2 || !s.startsWith("\\"") || !s.endsWith("\\"")) return s;/'
  mutate "encode lets a tab into the PSK"                       $L 's/if (psk.contains("\\t") || psk.contains("\\n")) return null;/if (psk.contains("\\n")) return null;/'
  mutate "maybeMirrorWifi reads through the trimming helper"    src/com/nowhere/chooser/ChooserActivity.java 's/DaemonSocket.roundTripLinesRaw("GET-WIFI-MIRROR/sendDaemonLines("GET-WIFI-MIRROR/'
  mutate "roundTripLinesRaw trims each line"                    src/com/nowhere/chooser/DaemonSocket.java 's/if (!line.trim().isEmpty()) lines.add(line);/line = line.trim(); if (!line.isEmpty()) lines.add(line);/'
  mutate "adoptRequest swaps added and present"                 $L 's/+ added + "\\n" + present +/+ present + "\\n" + added +/'
  mutate "maybeMirrorWifi logs adopted without the id branch"   src/com/nowhere/chooser/ChooserActivity.java 's/if (id >= 0) {/if (true) {/'
  mutate "maybeMirrorWifi no longer sends the adopt counts"     src/com/nowhere/chooser/ChooserActivity.java 's/WifiMirrorLine.adoptRequest(pass, added, present, failed)/""/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
