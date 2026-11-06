#!/usr/bin/env bash
# run.sh <QrOpenGate.java> <QrLuma.java> <QrScanActivity.java> -- NWP-20261113-29: compile the REAL QrOpenGate and QrLuma
# (unchanged) with QrScanCases and run it, then pin QrScanActivity's use of them (openCamera, stateCb, closeCamera,
# decode) on a comment-free copy, so prose cannot satisfy a pin. $JAVAC / $JAVA come from core/chooser/test-qrscan-java.sh.
# Exit codes: 1 = a case or a pin failed; 3 = the sources did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
U="usage: run.sh QrOpenGate.java QrLuma.java QrScanActivity.java"
GATE="${1:?$U}"
LUMA="${2:?$U}"
ACT="${3:?$U}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${QRSCAN_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$GATE" "$D/src/com/nowhere/chooser/QrOpenGate.java"
cp "$LUMA" "$D/src/com/nowhere/chooser/QrLuma.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/QrOpenGate.java" \
    "$D/src/com/nowhere/chooser/QrLuma.java" "$here/QrScanCases.java" 2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.QrScanCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# ---- source pins on QrScanActivity (string-literal-aware comment strip first).
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }
strip_java "$ACT" > "$D/act.java"

pin() { # pin <name> <command...>: PASS when the command succeeds
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "--- PASS: pin: $name"; else echo "--- FAIL: pin: $name"; rc=1; fi
}
# body <file> <signature text>: the method from its signature (a literal substring) to the closing brace at four-space indent.
body() { awk -v sig="$2" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$1"; }
body "$D/act.java" 'private void openCamera() {' > "$D/open.txt"
body "$D/act.java" 'private void closeCamera() {' > "$D/close.txt"
body "$D/act.java" 'private Result decode(Image img) {' > "$D/decode.txt"
awk 'index($0, "private CameraDevice.StateCallback stateCb(final int at) {") {f=1} f{print} f&&/^    }; }$/{exit}' "$D/act.java" \
  > "$D/cb.txt"
for f in open close decode cb; do
  [ -s "$D/$f.txt" ] || { echo "--- FAIL: pin: $f not found"; rc=1; }
done
# count <fixed string> <file>: occurrences, the whole file read (grep -c exits 1 on zero; that is a count, not an error).
count() { local n; n=$(grep -cF -- "$1" "$2" || true); echo "${n:-0}"; }

pin "P1 the gate field is declared" grep -qF 'private final QrOpenGate gate = new QrOpenGate();' "$D/act.java"
pin "P2 openCamera's first statement is the gate.begin() check" \
  perl -0ne 'exit !(/private void openCamera\(\) \{\s*if \(!gate\.begin\(\)\) return;/)' "$D/open.txt"
pin "P3 openCamera no longer guards on camera != null" test "$(count 'if (camera != null) return;' "$D/open.txt")" = 0
pin "P4 no camera id clears the gate" grep -qF 'if (camId == null) { gate.failed(); cancel(); return; }' "$D/open.txt"
pin "P4 the permission re-check clears the gate" grep -qF 'PERMISSION_GRANTED) { gate.failed(); return; }' "$D/open.txt"
pin "P4 the catch clears the gate" perl -0ne 'exit !(/catch \(Throwable t\) \{\s*gate\.failed\(\);/)' "$D/open.txt"
pin "P4 the ImageReader is created after the gate admitted the open" \
  perl -0ne 'exit !(/gate\.begin\(\).*reader = ImageReader\.newInstance\(/s)' "$D/open.txt"
pin "P12 openCamera binds the device callback to the attempt the gate admitted" \
  perl -0ne 'exit !(/if \(!gate\.begin\(\)\) return;\s*final int at = gate\.attempt\(\);.*cm\.openCamera\(camId, stateCb\(at\), bg\);/s)' "$D/open.txt"
pin "P5 onOpened closes a stale attempt's device, then one landing after the answer, then takes it" \
  perl -0ne 'exit !(/void onOpened\(CameraDevice c\) \{\s*if \(!gate\.opened\(at, c\)\) \{[^\n]*c\.close\(\);[^\n]*return; \}[^\n]*\n\s*if \(finished\) \{[^\n]*c\.close\(\);[^\n]*return; \}\s*camera = c;/)' "$D/cb.txt"
pin "P6 onDisconnected checks isCurrent before closeCamera()" \
  perl -0ne 'exit !(/void onDisconnected\(CameraDevice c\) \{(.*?)closeCamera\(\);/s && $1 =~ /if \(!gate\.isCurrent\(c\)\) \{.*?return;/s)' "$D/cb.txt"
pin "P7 onError checks isCurrent before closeCamera()" \
  perl -0ne 'exit !(/void onError\(CameraDevice c, int e\) \{(.*?)closeCamera\(\);/s && $1 =~ /if \(!gate\.isCurrent\(c\)\) \{.*?return;/s)' "$D/cb.txt"
pin "P8 onError cancels only when its own attempt's open was refused" \
  perl -0ne 'exit !(/void onError\(CameraDevice c, int e\) \{\s*if \(!gate\.isCurrent\(c\)\) \{[^\n]*\n[^\n]*c\.close\(\);[^\n]*\n\s*if \(gate\.openRefused\(at\)\) cancel\(\);/)' "$D/cb.txt"
pin "P13 onDisconnected clears only its own attempt's refused open" \
  perl -0ne 'exit !(/void onDisconnected\(CameraDevice c\) \{\s*if \(!gate\.isCurrent\(c\)\) \{[^\n]*\n[^\n]*c\.close\(\);[^\n]*\n\s*gate\.openRefused\(at\);/)' "$D/cb.txt"
pin "P9 closeCamera calls gate.reset()" grep -qF 'gate.reset();' "$D/close.txt"
pin "P10 decode calls QrLuma.luminance" grep -qF 'QrLuma.luminance(buf, w, h, rowStride)' "$D/decode.txt"
pin "P11 decode no longer breaks on buf.remaining() < rowStride" \
  test "$(count 'buf.remaining() < rowStride' "$D/decode.txt")" = 0
exit "$rc"
