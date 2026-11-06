#!/usr/bin/env bash
# test-qrscan-java.sh [--mutate] -- QrOpenGate and QrLuma, the QR scanner's camera-open gate and Y-plane copy, compiled
# UNCHANGED under javac and RUN, plus source pins on QrScanActivity (NWP-20261113-29).
#
# WHY THIS IS COMMITTED. QrScanActivity.openCamera guarded on `camera != null`, which is set only when the open lands on
# the bg thread, so on a first run the permission grant and onResume both opened the camera; the second open evicted the
# first, whose onDisconnected closed the shared session, camera and reader, and the scanner closed at once (the second
# tap worked). decode's copy broke on `remaining < rowStride`, and a padded Y plane's last row has no padding, so the
# last row was always left zero. A callback queued by an open that onPause reset (quitSafely still delivers it) must
# not clear, take over or cancel the open onResume began after it: G5/G6 and M12-M16. M1 and M4 below ARE the
# pre-change logic; M5 and M7 restore the pre-change source.
# What it does NOT prove: the device first-run scan (fresh install, grant the camera, the scanner stays open and reads a
# code) and the camera2 callbacks' android behaviour, which are source-pinned only (the chooser cannot be compiled off
# the build host).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-qrscan-java.sh            # the cases and pins
#   bash test-qrscan-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/src/com/nowhere/chooser/QrOpenGate.java"
LUMA="$HERE/src/com/nowhere/chooser/QrLuma.java"
ACT="$HERE/src/com/nowhere/chooser/QrScanActivity.java"
RUN="$HERE/tests/qrscan/run.sh"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$GATE" "$LUMA" "$ACT" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export QRSCAN_TMP="$W"

# suite <QrOpenGate> <QrLuma> <QrScanActivity> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict),
# 3 no compile.
suite() { bash "$RUN" "$1" "$2" "$3"; }

echo "== $GATE $LUMA $ACT"
out=$(suite "$GATE" "$LUMA" "$ACT" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: gate|luma|act> <perl-expr>
  local d m rc o orig g l a f first; d=$(mktemp -d -p "$W")
  g="$GATE"; l="$LUMA"; a="$ACT"
  case "$2" in
    gate) orig="$GATE"; f=QrOpenGate.java; m="$d/$f"; g="$m" ;;
    luma) orig="$LUMA"; f=QrLuma.java; m="$d/$f"; l="$m" ;;
    act) orig="$ACT"; f=QrScanActivity.java; m="$d/$f"; a="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$g" "$l" "$a" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then
         first=$(sed -n '/--- FAIL/{p;q;}' <<<"$o")
         echo "  convicted $1 -- $first"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 begin() admits while an open is in flight (the pre-change guard)" gate \
  's/if \(inFlight \|\| held != null\) return false;/if (held != null) return false;/' || fails=$((fails+1))
mut "M2 failed() does not clear the in-flight open" gate \
  's/(synchronized void failed\(\) \{) inFlight = false; \}/$1 }/' || fails=$((fails+1))
mut "M3 reset() leaves the current device" gate \
  's/(synchronized void reset\(\) \{ inFlight = false;) held = null; \}/$1 }/' || fails=$((fails+1))
mut "M4 QrLuma breaks on remaining < rowStride (the pre-change copy)" luma \
  's/int base = b\.position\(\), end = b\.limit\(\);\n\s*for \(int r = 0; r < h; r\+\+\) \{.*?\n        \}\n/byte[] row = new byte[rowStride];\n        for (int r = 0; r < h; r++) {\n            if (b.remaining() < rowStride) break;\n            b.get(row, 0, rowStride);\n            System.arraycopy(row, 0, y, r * w, w);\n        }\n/s' \
  || fails=$((fails+1))
mut "M5 openCamera's guard restored to camera != null" act \
  's/if \(!gate\.begin\(\)\) return;/if (camera != null) return;/' || fails=$((fails+1))
mut "M6 the isCurrent check removed from onDisconnected" act \
  's/(void onDisconnected\(CameraDevice c\) \{)\n\s*if \(!gate\.isCurrent\(c\)\) \{.*?\n\s*return;\n\s*\}/$1/s' || fails=$((fails+1))
mut "M7 decode's inline copy loop restored" act \
  's/byte\[\] y = QrLuma\.luminance\(buf, w, h, rowStride\);[^\n]*/byte[] y = new byte[w * h];\n        if (rowStride == w) {\n            buf.get(y, 0, Math.min(buf.remaining(), y.length));\n        } else { \/\/ strip row padding\n            byte[] row = new byte[rowStride];\n            for (int r = 0; r < h; r++) {\n                if (buf.remaining() < rowStride) break;\n                buf.get(row, 0, rowStride);\n                System.arraycopy(row, 0, y, r * w, w);\n            }\n        }/' \
  || fails=$((fails+1))
mut "M8 openRefused() does not clear the in-flight open" gate \
  's/(if \(!inFlight \|\| held != null \|\| at != attempt\) return false;)\n\s*inFlight = false;/$1/' || fails=$((fails+1))
mut "M9 onError no longer cancels a refused open" act \
  's/if \(gate\.openRefused\(at\)\) cancel\(\);/gate.openRefused(at);/' || fails=$((fails+1))
mut "M10 onOpened keeps the camera after the scanner answered" act \
  's/\n\s*if \(finished\) \{ try \{ c\.close\(\); \} catch \(Throwable ignore\) \{\} return; \}[^\n]*//' || fails=$((fails+1))
mut "M11 closeCamera no longer resets the gate" act 's/\n\s*gate\.reset\(\);//' || fails=$((fails+1))
mut "M12 openRefused() ignores the attempt (a stale callback clears and cancels a newer open)" gate \
  's/if \(!inFlight \|\| held != null \|\| at != attempt\) return false;/if (!inFlight || held != null) return false;/' \
  || fails=$((fails+1))
mut "M13 opened() ignores the attempt (a stale device lands as current)" gate \
  's/if \(!inFlight \|\| at != attempt\) return false;/if (false) return false;/' || fails=$((fails+1))
mut "M14 begin() does not number a new attempt" gate 's/\n\s*attempt\+\+;//' || fails=$((fails+1))
mut "M15 onError refuses through any attempt (the unbound openRefused)" act \
  's/if \(gate\.openRefused\(at\)\) cancel\(\);/if (gate.openRefused(gate.attempt())) cancel();/' || fails=$((fails+1))
mut "M16 onOpened takes a stale attempt's device" act \
  's/if \(!gate\.opened\(at, c\)\) \{ try \{ c\.close\(\); \} catch \(Throwable ignore\) \{\} return; \}/gate.opened(at, c);/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
