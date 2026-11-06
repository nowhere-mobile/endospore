#!/usr/bin/env bash
# run.sh <Fido2KeyList.java> <ProfileActivity.java> <main.go> <NfcFido2.java> -- NWP-20261114-29: compile the REAL
# Fido2KeyList (unchanged), run Fido2KeyListCases, then pin ProfileActivity.loadEnrolledKeys' body (comments dropped
# first, so prose cannot satisfy a pin). NWP-20261116-29: also pin confirmRemoveKey's reply block (Fido2KeyList.removeText,
# and the list reloaded on every reply) and the replies main.go's REMOVE-FIDO2-KEY arm writes (NWP-20261127-02 adds
# ERR-NOTSTORED, ERR-NOKEY and ERR-WRONGKEY, the fresh-tap replies).
# NWP-20261119-11: also pin showAddSecurityKey's ENROLL-FIDO2 read and NfcFido2.run's shuttle read to outlast the
# deadlines main.go's ENROLL-FIDO2 and FIDO2-NFC-ENROLL-FINISH arms set (read from main.go, never hard-coded), the
# replies rendered through Fido2KeyList.enrollText / nfcFinishText, and armGate's 40 s read. All four inputs are required.
# $JAVAC / $JAVA come from core/chooser/test-fido2-key-list-java.sh.
# Exit codes: 1 = a case or a pin failed; 3 = the sources did not compile, an input is missing, or the JVM died with
# anything but 0/1.
set -euo pipefail
U="usage: run.sh Fido2KeyList.java ProfileActivity.java main.go NfcFido2.java"
if [ "$#" -ne 4 ]; then echo "$U" >&2; exit 3; fi
SRC=$1 PA=$2 MAIN=$3 NF=$4
here=$(cd "$(dirname "$0")" && pwd)
for f in "$SRC" "$PA" "$MAIN" "$NF"; do
  [ -f "$f" ] || { echo "run.sh: missing $f" >&2; exit 3; }
done
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
D=$(mktemp -d -p "${FIDO2_KEY_LIST_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/Fido2KeyList.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/Fido2KeyList.java" \
    "$here/Fido2KeyListCases.java" 2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.Fido2KeyListCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# Source pins: loadEnrolledKeys reads its list through Fido2KeyList.parse and keeps no loop of its own.
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }
strip_java "$PA" > "$D/pa.java"
SIG='private void loadEnrolledKeys(final LinearLayout keyList, final Button enroll) {'
n=$(grep -c -F "$SIG" "$D/pa.java" || true)
if [ "$n" != 1 ]; then echo "--- FAIL: pin: the loadEnrolledKeys signature occurs $n time(s), want 1"; exit 1; fi
body=$(awk -v sig="$SIG" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$D/pa.java")
case "$body" in
  *"Fido2KeyList.parse(reply)"*) echo "--- PASS: pin: loadEnrolledKeys calls Fido2KeyList.parse(reply)" ;;
  *) echo "--- FAIL: pin: loadEnrolledKeys does not call Fido2KeyList.parse(reply)"; rc=1 ;;
esac
case "$body" in
  *'line.startsWith("OK")'*) echo "--- FAIL: pin: loadEnrolledKeys still skips every line starting OK"; rc=1 ;;
  *) echo "--- PASS: pin: no line.startsWith(\"OK\") left in loadEnrolledKeys" ;;
esac
case "$body" in
  *LIST-FIDO2*) echo "--- PASS: pin: control: LIST-FIDO2 occurs in loadEnrolledKeys" ;;
  *) echo "--- FAIL: pin: control: LIST-FIDO2 not found in loadEnrolledKeys (the extraction is wrong)"; rc=1 ;;
esac

# NWP-20261116-29: confirmRemoveKey's runOnUiThread block shows Fido2KeyList.removeText(r) and reloads the list on
# EVERY reply. A lost reply ("") can follow a committed vault write, so no reply may keep the old list.
CSIG='private void confirmRemoveKey(final String credID, String label, boolean last,'
n=$(grep -c -F "$CSIG" "$D/pa.java" || true)
if [ "$n" != 1 ]; then echo "--- FAIL: pin: the confirmRemoveKey signature occurs $n time(s), want 1"; exit 1; fi
cbody=$(awk -v sig="$CSIG" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$D/pa.java")
case "$cbody" in
  *REMOVE-FIDO2-KEY*) echo "--- PASS: pin: control: REMOVE-FIDO2-KEY occurs in confirmRemoveKey" ;;
  *) echo "--- FAIL: pin: control: REMOVE-FIDO2-KEY not found in confirmRemoveKey (the extraction is wrong)"; rc=1 ;;
esac
nui=$(grep -c -F 'runOnUiThread(() -> {' <<< "$cbody" || true)
ui=$(awk 'index($0, "runOnUiThread(() -> {") {f=1} f{print} f{t=$0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == "});") exit}' <<< "$cbody")
if [ "$nui" != 1 ] || [ -z "$ui" ]; then
  echo "--- FAIL: pin: confirmRemoveKey holds $nui runOnUiThread block(s), want 1 -- this pin is stale"; rc=1
else
  case "$ui" in
    *"Fido2KeyList.removeText(r)"*) echo "--- PASS: pin: confirmRemoveKey's reply block shows Fido2KeyList.removeText(r)" ;;
    *) echo "--- FAIL: pin: confirmRemoveKey's reply block does not show Fido2KeyList.removeText(r)"; rc=1 ;;
  esac
  case "$ui" in
    *"loadEnrolledKeys(keyList, enroll);"*) echo "--- PASS: pin: confirmRemoveKey's reply block calls loadEnrolledKeys(keyList, enroll)" ;;
    *) echo "--- FAIL: pin: confirmRemoveKey's reply block does not call loadEnrolledKeys(keyList, enroll)"; rc=1 ;;
  esac
  if [[ "$ui" =~ (^|[^A-Za-z0-9_])if[[:space:]]*\( ]]; then
    echo "--- FAIL: pin: confirmRemoveKey's reply block holds an if (the list must be reloaded on every reply)"; rc=1
  else
    echo "--- PASS: pin: confirmRemoveKey's reply block holds no if"
  fi
  case "$ui" in
    *'"'*) echo "--- FAIL: pin: confirmRemoveKey's reply block holds a reply literal (the text belongs in removeText)"; rc=1 ;;
    *) echo "--- PASS: pin: confirmRemoveKey's reply block holds no string literal" ;;
  esac
  case "$ui" in
    *startsWith*|*"contains("*|*"?"*) echo "--- FAIL: pin: confirmRemoveKey's reply block tests the reply itself"; rc=1 ;;
    *) echo "--- PASS: pin: confirmRemoveKey's reply block does not test the reply itself" ;;
  esac
fi

# NWP-20261116-29: every reply main.go's REMOVE-FIDO2-KEY arm writes is one removeText classifies. A new reply fails
# here until it is classified there; a moved or renamed arm fails as stale, never passes.
ARM=$'\tif name == "REMOVE-FIDO2-KEY" {'
n=$(grep -c -x -F "$ARM" "$MAIN" || true)
if [ "$n" != 1 ]; then
  echo "--- FAIL: pin: the REMOVE-FIDO2-KEY arm occurs $n time(s) in main.go, want 1 -- this pin is stale"; exit 1
fi
awk -v arm="$ARM" '$0 == arm {f=1} f{print} f && $0 == "\t}" {exit}' "$MAIN" > "$D/arm.go"
strip_java "$D/arm.go" > "$D/arm.stripped"
# Every write to conn, one per line: the fmt.Fprint* calls this pin reads, then every form it might not read.
writes=$(perl -ne 'while (/(fmt\.Fprint(?:f|ln)?\(\s*conn\b.*)$/g) { my $s = $1; $s =~ s/\s+$//; print "$s\n" }' "$D/arm.stripped")
raw=$(perl -ne 'print if /conn\.Write|WriteString\(\s*conn|io\.Copy\(\s*conn|Fprint\w*\(\s*conn\b/' "$D/arm.stripped")
A1='fmt.Fprint(conn, "ERR-NOSESSION\n")'
A2='fmt.Fprintf(conn, "OK %v\n", stillEnrolled)'
A3='fmt.Fprint(conn, "ERR\n")'
# NWP-20261127-02: the fresh-tap replies.
A4='fmt.Fprint(conn, "ERR-NOTSTORED\n")'
A5='fmt.Fprint(conn, "ERR-NOKEY\n")'
A6='fmt.Fprint(conn, "ERR-WRONGKEY\n")'
armok=1
nw=0
while IFS= read -r w; do
  [ -n "$w" ] || continue
  nw=$((nw+1))
  case "$w" in
    "$A1"|"$A2"|"$A3"|"$A4"|"$A5"|"$A6") ;;
    *) echo "--- FAIL: pin: the REMOVE-FIDO2-KEY arm writes an unclassified reply: $w -- classify it in Fido2KeyList.removeText, then add it here"; armok=0; rc=1 ;;
  esac
done <<< "$writes"
nraw=$(grep -c . <<< "$raw" || true)
if [ "$nraw" != "$nw" ]; then
  echo "--- FAIL: pin: the REMOVE-FIDO2-KEY arm writes to conn in a form this pin does not read ($nraw write line(s), $nw read) -- classify it"; armok=0; rc=1
fi
if [ "$nw" = 0 ]; then
  echo "--- FAIL: pin: the REMOVE-FIDO2-KEY arm writes no reply this pin reads -- this pin is stale"; armok=0; rc=1
fi
for want in "$A1" "$A2" "$A3" "$A4" "$A5" "$A6"; do
  case $'\n'"$writes"$'\n' in
    *$'\n'"$want"$'\n'*) ;;
    *) echo "--- FAIL: pin: the REMOVE-FIDO2-KEY arm no longer writes $want -- this pin is stale"; armok=0; rc=1 ;;
  esac
done
[ "$armok" = 0 ] || echo "--- PASS: pin: the REMOVE-FIDO2-KEY arm writes only ERR-NOSESSION, OK <stillEnrolled>, ERR, ERR-NOTSTORED, ERR-NOKEY and ERR-WRONGKEY"

# NWP-20261119-11: an enrol read must outlast the arm's deadline. The arm writes OK only after the paid vault write, so a
# read that gives up first reports a committed enrolment as a failed one. deadline_of <arm line> <label> prints the
# seconds of the arm's only conn.SetDeadline, or "" (and a FAIL) when the arm or its deadline is missing or doubled.
deadline_of() {
  local arm=$1 label=$2 n secs
  n=$(grep -c -x -F "$arm" "$MAIN" || true)
  if [ "$n" != 1 ]; then
    echo "--- FAIL: pin: the $label arm occurs $n time(s) in main.go, want 1 -- this pin is stale" >&2; return 1
  fi
  secs=$(awk -v arm="$arm" '$0 == arm {f=1} f{print} f && $0 == "\t}" {exit}' "$MAIN" | strip_java /dev/stdin \
    | perl -ne 'print "$1\n" while /conn\.SetDeadline\(time\.Now\(\)\.Add\(([0-9]+) \* time\.Second\)\)/g')
  if ! [[ "$secs" =~ ^[0-9]+$ ]]; then
    echo "--- FAIL: pin: the $label arm holds no single conn.SetDeadline(time.Now().Add(<n> * time.Second)) -- this pin is stale" >&2
    return 1
  fi
  printf '%s\n' "$secs"
}
# outlasts <label> <read-ms> <arm-seconds>: the read in ms is a number and greater than 1000 times the arm's seconds.
outlasts() {
  local label=$1 ms=$2 secs=$3
  if ! [[ "$ms" =~ ^[0-9]+$ ]] || ! [[ "$secs" =~ ^[0-9]+$ ]]; then
    echo "--- FAIL: pin: $label: the read ($ms) or the deadline ($secs) is not a number"; rc=1
  elif [ $((10#$ms)) -gt $((10#$secs * 1000)) ]; then
    echo "--- PASS: pin: $label reads for $ms ms, past the arm's $secs s"
  else
    echo "--- FAIL: pin: $label reads for $ms ms, not past the arm's $secs s"; rc=1
  fi
}
ENROLL_S=$(deadline_of $'\tif name == "ENROLL-FIDO2" {' ENROLL-FIDO2) || rc=1
FINISH_S=$(deadline_of $'\tif name == "FIDO2-NFC-ENROLL-FINISH" {' FIDO2-NFC-ENROLL-FINISH) || rc=1

SSIG='private void showAddSecurityKey(final String flash) {'
n=$(grep -c -F "$SSIG" "$D/pa.java" || true)
if [ "$n" != 1 ]; then echo "--- FAIL: pin: the showAddSecurityKey(flash) signature occurs $n time(s), want 1"; exit 1; fi
sbody=$(awk -v sig="$SSIG" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$D/pa.java")
case "$sbody" in
  *FIDO2-NFC-ENROLL-FINISH*) echo "--- PASS: pin: control: FIDO2-NFC-ENROLL-FINISH occurs in showAddSecurityKey" ;;
  *) echo "--- FAIL: pin: control: FIDO2-NFC-ENROLL-FINISH not found in showAddSecurityKey (the extraction is wrong)"; rc=1 ;;
esac
# The source holds a literal backslash-n inside the string.
calls=$(perl -ne 'print "$1\n" while /DaemonSocket\.roundTrip\("ENROLL-FIDO2\\n", ([0-9]+)\)/g' <<< "$sbody")
if [ "$(grep -c . <<< "$calls" || true)" != 1 ]; then
  echo "--- FAIL: pin: showAddSecurityKey holds $(grep -c . <<< "$calls" || true) DaemonSocket.roundTrip(\"ENROLL-FIDO2\\n\", <ms>) call(s), want 1"; rc=1
else
  outlasts "the ENROLL-FIDO2 call" "$calls" "$ENROLL_S"
fi
case "$sbody" in
  *'sendDaemon("ENROLL-FIDO2'*) echo "--- FAIL: pin: showAddSecurityKey still sends ENROLL-FIDO2 through sendDaemon (a 90 s read)"; rc=1 ;;
  *) echo "--- PASS: pin: showAddSecurityKey does not send ENROLL-FIDO2 through sendDaemon" ;;
esac
# count <fixed text> <haystack>: how many times the text occurs.
count() { perl -e 'my ($n, $s) = (shift, join("", <STDIN>)); my $c = () = $s =~ /\Q$n\E/g; print "$c\n"' "$1" <<< "$2"; }
pin_count() { # pin_count <text> <want> <what>
  local c; c=$(count "$1" "$sbody")
  if [ "$c" = "$2" ]; then echo "--- PASS: pin: showAddSecurityKey holds $2 $3"
  else echo "--- FAIL: pin: showAddSecurityKey holds $c $3, want $2"; rc=1; fi
}
pin_count 'Fido2KeyList.enrollText(r)' 1 'Fido2KeyList.enrollText(r) (the USB reply text)'
pin_count 'Fido2KeyList.nfcFinishText(detail2)' 1 'Fido2KeyList.nfcFinishText(detail2) (the FINISH failure text)'
pin_count '.equals(Fido2KeyList.ENROLL_MAY_HAVE_ADDED)' 2 'test(s) for the may-have-been-added text (USB and FINISH)'
pin_count 'showAddSecurityKey(t);' 2 're-render(s) with that text, which reload the list (USB and FINISH)'
case "$sbody" in
  *"\"Couldn't enroll"*|*'"The second tap didn'*) echo "--- FAIL: pin: showAddSecurityKey still holds its own enrol failure text"; rc=1 ;;
  *) echo "--- PASS: pin: showAddSecurityKey holds no enrol failure text of its own (it lives in Fido2KeyList)" ;;
esac

# NfcFido2: shuttle takes the read timeout; run() (the enrol taps) reads past the FINISH arm; armGate keeps 40 s.
strip_java "$NF" > "$D/nf.java"
nf_body() { awk -v sig="$1" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$D/nf.java"; }
SHSIG='private static String[] shuttle(final IsoDep iso, String verbLines, int apduTimeoutMs, int socketTimeoutMs)'
n=$(grep -c -F "$SHSIG" "$D/nf.java" || true)
if [ "$n" != 1 ]; then
  echo "--- FAIL: pin: the shuttle(..., int apduTimeoutMs, int socketTimeoutMs) signature occurs $n time(s), want 1"; rc=1
else
  shbody=$(nf_body "$SHSIG")
  st=$(count 'setSoTimeout(' "$shbody"); sst=$(count 's.setSoTimeout(socketTimeoutMs);' "$shbody")
  if [ "$st" = 1 ] && [ "$sst" = 1 ]; then echo "--- PASS: pin: shuttle's only setSoTimeout is s.setSoTimeout(socketTimeoutMs)"
  else echo "--- FAIL: pin: shuttle holds $st setSoTimeout call(s) and $sst s.setSoTimeout(socketTimeoutMs), want 1 and 1"; rc=1; fi
fi
ncalls=$(perl -ne 'print "x\n" while /\bshuttle\(/g' "$D/nf.java" | grep -c . || true)
if [ "$ncalls" = 3 ]; then echo "--- PASS: pin: NfcFido2 calls shuttle twice (armGate and run)"
else echo "--- FAIL: pin: NfcFido2 holds $ncalls shuttle( occurrence(s), want 3 (the signature, armGate, run)"; rc=1; fi
rbody=$(nf_body 'static void run(final Activity act, final String verbLines, final Result cb) {')
rms=$(perl -ne 'print "$1\n" while /shuttle\(iso, verbLines, APDU_TIMEOUT_ENROLL_MS, ([0-9]+)\)/g' <<< "$rbody")
if [ "$(grep -c . <<< "$rms" || true)" != 1 ]; then
  echo "--- FAIL: pin: run() holds no single shuttle(iso, verbLines, APDU_TIMEOUT_ENROLL_MS, <ms>) call"; rc=1
else
  outlasts "run()'s shuttle (the FIDO2-NFC-ENROLL-FINISH tap)" "$rms" "$FINISH_S"
fi
gbody=$(nf_body 'static boolean armGate(final Activity act, final VerbSupplier verbSupplier, final Result cb) {')
g=$(count 'shuttle(iso, verb, APDU_TIMEOUT_MS, 40000)' "$gbody")
if [ "$g" = 1 ]; then echo "--- PASS: pin: armGate's shuttle still reads for 40000 ms"
else echo "--- FAIL: pin: armGate holds $g shuttle(iso, verb, APDU_TIMEOUT_MS, 40000) call(s), want 1"; rc=1; fi
exit "$rc"
