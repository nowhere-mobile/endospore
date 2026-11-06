#!/usr/bin/env bash
# test-fido2-key-list-java.sh [<Fido2KeyList.java>] [--mutate] -- Fido2KeyList.parse, the parse of the daemon's
# LIST-FIDO2 reply, compiled UNCHANGED under javac and RUN (NWP-20261114-29).
#
# WHY THIS IS COMMITTED. ProfileActivity.loadEnrolledKeys skipped every reply line that began "OK", not only the
# "OK <n>" header. A credID is standard base64, so a random one begins "OK" for about 1 key in 4096: that key was
# hidden, and a profile whose only key it was read "Enroll the key". The parse now lives in Fido2KeyList, where only
# line 1 is the header. M1 below IS the pre-change loop; M6 restores it in loadEnrolledKeys (the source pins).
# NWP-20261116-29: also Fido2KeyList.removeText, the text for a REMOVE-FIDO2-KEY reply, which matches the WHOLE first
# token. confirmRemoveKey used to reload the list only on "OK...", so a lost reply ("") after a committed vault write said
# "Couldn't remove the key" and kept the removed key on the list. The pins hold confirmRemoveKey's reply block to
# removeText plus a reload on every reply, and main.go's REMOVE-FIDO2-KEY arm to the three replies removeText knows
# (ERR-NOSESSION, OK <stillEnrolled>, ERR). Mutants F1-F5 break each of those.
# NWP-20261119-11: also Fido2KeyList.enrollText (an ENROLL-FIDO2 reply) and nfcFinishText (a failed NFC FINISH). Add a
# security key read ENROLL-FIDO2 for 90 s and the NFC FINISH for 40 s a line, against the daemon's 120 s arms, so an
# enrolment that committed said "Couldn't enroll" and the list was not reloaded. The pins read each arm's deadline from
# main.go and hold the USB read (DaemonSocket.roundTrip) and NfcFido2.run's shuttle read past it, armGate's shuttle at
# 40 s, and both replies rendered through Fido2KeyList with a re-render on a lost or closed reply. Mutants E1-E10.
# NWP-20261127-02: a key removal needs a fresh tap over USB-C, and the REMOVE-FIDO2-KEY arm gains ERR-NOTSTORED,
# ERR-NOKEY ("Plug in one of your keys to remove a key.") and ERR-WRONGKEY. removeText words each; the arm pin above
# holds all six replies. Mutants F6-F7 map ERR-WRONGKEY and ERR-NOKEY to the generic retry text.
# What it does NOT prove: the security-keys screen on a device (the chooser cannot be compiled off the build host).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-fido2-key-list-java.sh            # the cases and the pins
#   bash test-fido2-key-list-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/Fido2KeyList.java"
PA="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MAIN="$HERE/../agent/main.go"
NF="$HERE/src/com/nowhere/chooser/NfcFido2.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/fido2-key-list/run.sh"
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
for f in "$SRC" "$PA" "$MAIN" "$NF" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export FIDO2_KEY_LIST_TMP="$W"

# suite <Fido2KeyList> <ProfileActivity> <main.go> <NfcFido2> -> run.sh's code: 0 pass, 1 a case or pin failed (only
# this may convict), 3 no compile.
suite() { bash "$RUN" "$1" "$2" "$3" "$4"; }

echo "== $SRC"
out=$(suite "$SRC" "$PA" "$MAIN" "$NF" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: list|pa|main|nfc> <perl-expr>
  local d m rc o orig l p g n f; d=$(mktemp -d -p "$W")
  l="$SRC"; p="$PA"; g="$MAIN"; n="$NF"
  case "$2" in
    list) orig="$SRC"; f=Fido2KeyList.java; m="$d/$f"; l="$m" ;;
    pa) orig="$PA"; f=ProfileActivity.java; m="$d/$f"; p="$m" ;;
    main) orig="$MAIN"; f=main.go; m="$d/$f"; g="$m" ;;
    nfc) orig="$NF"; f=NfcFido2.java; m="$d/$f"; n="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$l" "$p" "$g" "$n" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; printf '%s\n' "$o" | sed -n 's/^--- FAIL/            --- FAIL/p'; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
# M6's replacement: origin/main's loop in loadEnrolledKeys, verbatim (perl reads it from the environment).
OLD=$(cat <<'OLDLOOP'
            final java.util.ArrayList<String[]> keys = new java.util.ArrayList<>(); // {credID, added, transport, label}
            for (String line : reply.split("\n")) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("OK") || line.equals("NONE") || line.equals("LOCAL")) continue;
                // "<credID> <added> <transport> [label]". transport is a fixed 3rd field ("usb"/"nfc"/"-"), so the
                // label stays "the rest of the line" (usually EMPTY -> the line is 3 tokens after trim()). Split
                // into at most 4 parts; a legacy daemon line with no transport field still yields >=2 and just
                // renders as the generic "Security key N".
                String[] parts = line.split(" ", 4);
                if (parts.length >= 2) {
                    String transport = parts.length >= 3 ? parts[2] : "";
                    String label = parts.length >= 4 ? parts[3] : "";
                    keys.add(new String[]{parts[0], parts[1], transport, label});
                }
            }
            // NWP-20261006-23: only OK, NONE and LOCAL are answers. ERR (a store read that failed) and "" (no reply)
            // used to render as an empty list under "Enroll the key": a profile with keys told it had none.
            final String head = reply.split("\n", 2)[0].trim();
            final boolean answered = head.startsWith("OK") || head.equals("NONE") || head.equals("LOCAL");
OLDLOOP
)
export OLD
fails=0
mut "M1 the pre-change loop (skips every line starting OK)" list \
  's/for \(int i = 1; i < lines\.length; i\+\+\) \{\n(\s*)String line = lines\[i\]\.trim\(\);\n(\s*)if \(line\.isEmpty\(\)\) continue;/for (int i = 0; i < lines.length; i++) {\n$1String line = lines[i].trim();\n$2if (line.isEmpty() || line.startsWith("OK") || line.equals("NONE") || line.equals("LOCAL")) continue;/' || fails=$((fails+1))
mut "M2 the header line is parsed as a record" list 's/for \(int i = 1;/for (int i = 0;/' || fails=$((fails+1))
mut "M3 NONE returns null" list 's/ \|\| head\.equals\("NONE"\)//' || fails=$((fails+1))
mut "M4 ERR returns an empty list" list 's/(head\.equals\("LOCAL"\)\)\)) return null;/$1 return new java.util.ArrayList<>();/' || fails=$((fails+1))
mut "M5 split without the limit" list 's/line\.split\(" ", 4\)/line.split(" ")/' || fails=$((fails+1))
mut "M6 loadEnrolledKeys' old loop restored" pa \
  's/[ \t]*\/\/ NWP-20261114-29: only the FIRST line[^\n]*\n[^\n]*\n[^\n]*\n[ \t]*final java\.util\.List<String\[\]> keys = Fido2KeyList\.parse\(reply\);[^\n]*\n[ \t]*final boolean answered = keys != null;\n/$ENV{OLD}\n/' || fails=$((fails+1))
mut "M7 a record line starting NONE or LOCAL is skipped" list \
  's/if \(line\.isEmpty\(\)\) continue;/if (line.isEmpty() || line.startsWith("NONE") || line.startsWith("LOCAL")) continue;/' || fails=$((fails+1))
mut "M8 the reply split drops empty fields (a newline-only reply throws)" list \
  's/reply\.split\("\\n", -1\)/reply.split("\\n")/' || fails=$((fails+1))
mut "F1 removeText maps a lost reply to the retry text" list 's/if \(first\.isEmpty\(\)\) \{/if (false) {/' || fails=$((fails+1))
mut "F2 the passphrase-only test by contains(\"false\")" list \
  's/t\.length >= 2 && t\[1\]\.equals\("false"\)/r.contains("false")/' || fails=$((fails+1))
mut "F3 confirmRemoveKey reloads the list only on OK" pa \
  's/(\n([ \t]*)loadEnrolledKeys\(keyList, enroll\);)(\n[ \t]*\}\);)/\n$2if (r.startsWith("OK")) loadEnrolledKeys(keyList, enroll);$3/' || fails=$((fails+1))
mut "F4 the REMOVE-FIDO2-KEY arm writes a new reply" main \
  's/(\n\tif name == "REMOVE-FIDO2-KEY" \{\n)/$1\t\tfmt.Fprint(conn, "ERR-NEW\\n")\n/' || fails=$((fails+1))
mut "F5 removeText's OK test by startsWith" list 's/first\.equals\("OK"\)/first.startsWith("OK")/' || fails=$((fails+1))
mut "F6 removeText maps ERR-WRONGKEY to the generic text" list 's/\n[ \t]*if \(first\.equals\("ERR-WRONGKEY"\)\)[^\n]*//' || fails=$((fails+1))
mut "F7 removeText maps ERR-NOKEY to the generic text" list 's/\n[ \t]*if \(first\.equals\("ERR-NOKEY"\)\)[^\n]*//' || fails=$((fails+1))
mut "E1 enrollText(\"\") returns the ERR line" list \
  's/if \(t\.isEmpty\(\)\) return ENROLL_MAY_HAVE_ADDED;/if (t.isEmpty()) return ENROLL_FAILED;/' || fails=$((fails+1))
mut "E2 enrollText matches by startsWith (ERR-NOTSTORED reads as ERR)" list \
  's/(\n([ \t]*)if \(t\.equals\("ERR-NOTSTORED"\)\))/\n$2if (t.startsWith("ERR")) return ENROLL_FAILED;$1/' || fails=$((fails+1))
mut "E3 nfcFinishText(\"nfc-io\") returns the start-over line" list 's/t\.equals\("nfc-io"\) \|\| //' || fails=$((fails+1))
mut "E4 nfcFinishText(\"closed\") returns the start-over line" list 's/ \|\| t\.equals\("closed"\)//' || fails=$((fails+1))
mut "E5 the ENROLL-FIDO2 call reverted to sendDaemon" pa \
  's/DaemonSocket\.roundTrip\("ENROLL-FIDO2\\n", 130000\)/sendDaemon("ENROLL-FIDO2\\n").trim()/' || fails=$((fails+1))
mut "E6 run() passes 40000" nfc 's/(shuttle\(iso, verbLines, APDU_TIMEOUT_ENROLL_MS, )130000/${1}40000/' || fails=$((fails+1))
mut "E7 main.go's ENROLL-FIDO2 deadline raised to 200 s" main \
  's/(\n\tif name == "ENROLL-FIDO2" \{\n.*?conn\.SetDeadline\(time\.Now\(\)\.Add\()120( \* time\.Second\))/${1}200$2/s' || fails=$((fails+1))
mut "E8 main.go's FIDO2-NFC-ENROLL-FINISH deadline raised to 200 s" main \
  's/(\n\tif name == "FIDO2-NFC-ENROLL-FINISH" \{\n.*?conn\.SetDeadline\(time\.Now\(\)\.Add\()120( \* time\.Second\))/${1}200$2/s' || fails=$((fails+1))
mut "E9 the USB lost reply no longer re-renders the list" pa \
  's/(Fido2KeyList\.enrollText\(r\);.*?)showAddSecurityKey\(t\);/${1}msg.setText(t);/s' || fails=$((fails+1))
mut "E10 armGate passes 130000" nfc 's/(shuttle\(iso, verb, APDU_TIMEOUT_MS, )40000/${1}130000/' || fails=$((fails+1))
mut "E11 the FINISH failure shows the start-over line for every detail" pa \
  's/Fido2KeyList\.nfcFinishText\(detail2\)/"The second tap didn\x27t complete."/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
