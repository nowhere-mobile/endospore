#!/usr/bin/env bash
# test-ticket-ledgers.sh [<ChooserActivity.java>] [<ProfileActivity.java>] [--mutate] -- the two past-report ledgers
# (the gate's nowhere-device-tickets.json, the Profile screen's nowhere-tickets.json) are written only by temp + rename,
# and neither is rewritten after a read failure.
#
# WHY THIS IS COMMITTED. The gate's ledger is durable on purpose: it must survive the power-off wipe so the reference
# outlives the reboot an OTA/setup failure usually involves. appendDeviceTicket wrote it through a FileWriter, which
# truncates at open: a report filed on a phone with almost no free space (the state that sends people to "Report an
# issue") failed after the truncate and lost every past reference. And readDeviceTickets / readTickets answered an
# empty array on ANY Throwable, so one failed read made the next append replace up to 20 (gate) or 50 (profile)
# references with one. Now each append reads the ledger's TEXT through readDeviceTicketsText / readTicketsText, which
# answer "" for an absent file and null for one that exists but cannot be read, and on null logs and writes nothing.
#
# WHAT IS PINNED, on each method's body found by its exact signature (EXTRACTION FAILED, exit 2, when an anchor moved;
# the two text readers are new, so their absence is a FAIL, which is what makes this suite red on the old code):
#   A1 each append: no `FileWriter(` and exactly one `StoreInstaller.writeAtomic(`, naming its own ledger;
#   A2 each append: `String text = <its text reader>();`, and `if (text == null) { ... return; }` before its
#      writeAtomic; it no longer reads through the array reader (whose catch answers "empty");
#   A3 each text reader: tests `exists()`, reads with `KeepOrder.readText(`, its catch returns null, and it has
#      exactly one `return "";` (the absent file); no `catch (Throwable ignore) { return new org.json.JSONArray(); }`
#      on an append path (the append and its text reader);
#   A4 each append: the lines this slice added (they carry NWP-20261111-24) name neither `ticket` nor `note`.
# Comments are stripped everywhere; string literals are blanked except where a ledger name is matched.
# The array readers (readDeviceTickets / readTickets, the render path) are pinned to read through their text reader.
# Controls: a fabricated FileWriter body is flagged by the A1 check, and a sound one passes.
#
#   bash test-ticket-ledgers.sh            # the pins
#   bash test-ticket-ledgers.sh --mutate   # ... plus four mutants, each CONVICTED alone
#
# Exit: 0 all pass, 1 a check failed, 2 the suite itself could not run.
set -uo pipefail

MUTATE=no; FILES=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) FILES+=("$a") ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="${FILES[0]:-$HERE/src/com/nowhere/chooser/ChooserActivity.java}"
PROF="${FILES[1]:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$GATE" ] || { echo "no such file: $GATE" >&2; exit 2; }
[ -f "$PROF" ] || { echo "no such file: $PROF" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# Every match reads its input to the end (here-strings, never `cmd | grep -q`): under pipefail grep -q can SIGPIPE
# its producer and fail the pipeline.

# strip <keep-literals 0|1>: the source with comments dropped; string, char and text-block literals emptied, or
# copied through whole when keep is 1.
strip(){ awk -v SQ="'" -v KEEP="$1" '
  BEGIN { inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) { if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3 } else i++; continue }
      if (two=="//") break
      if (two=="/*") { inblock=1; i+=2; continue }
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code "\"\""; continue }
      if (c=="\"" || c==SQ) {
        q=c; s=i; i++
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        i++
        if (KEEP==1) code=code substr($0, s, i-s); else code=code q q
        continue
      }
      code=code c; i++
    }
    print code
  }'; }
# method <file> <keep> <signature-regex>: the method from its signature line to the brace that closes it. Reads to
# EOF (an early exit would SIGPIPE strip); rc 3 when unbalanced or absent.
method(){ strip "$2" < "$1" | RE="$3" awk '
  !on && $0 ~ ENVIRON["RE"] { on=1 }
  on && !done { print; n=length($0); for (i=1;i<=n && !done;i++) { c=substr($0,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) done=1 } } }
  END { if (!done) exit 3 }'; }

# offset <haystack> <needle>: 1-based index of the first needle, 0 when absent.
offset(){ awk -v h="$1" -v n="$2" 'BEGIN { print index(h, n) }'; }

SWALLOW='catch(Throwableignore){returnneworg.json.JSONArray();}'

# check_a1 <label> <body-with-literals> <body-code-only> <ledger>
check_a1(){
  local label="$1" lit="$2" code="$3" ledger="$4" n flat got
  if grep -qE 'FileWriter[[:space:]]*\(' <<<"$code"; then no "$label: still writes through a FileWriter("; else ok "$label: no FileWriter("; fi
  n=$(grep -oF 'StoreInstaller.writeAtomic(' <<<"$lit" | wc -l)
  if [ "$n" -eq 1 ]; then ok "$label: one StoreInstaller.writeAtomic("; else no "$label: $n StoreInstaller.writeAtomic( calls, want exactly 1"; fi
  flat=$(tr -d '[:space:]' <<<"$lit")
  got=$(grep -oE 'StoreInstaller\.writeAtomic\([^;]*\);' <<<"$flat" | sed -E 's/^StoreInstaller\.writeAtomic\((.*),[^,]*\);$/\1/' | paste -sd';')
  if [ "$got" = "newjava.io.File(getFilesDir(),\"$ledger\")" ]; then ok "$label: writes $ledger"
  else no "$label: writeAtomic target '$got', want new java.io.File(getFilesDir(), \"$ledger\")"; fi
}

# check_append <label> <body-with-literals> <body-code-only> <ledger> <text-reader> <array-reader>
check_append(){
  local label="$1" lit="$2" code="$3" ledger="$4" reader="$5" arr="$6" flat null nullat writeat line c hits
  check_a1 "$label" "$lit" "$code" "$ledger"
  flat=$(tr -d '[:space:]' <<<"$code")
  # A2
  if grep -qF "Stringtext=$reader();" <<<"$flat"; then ok "$label: reads the ledger's text through $reader()"
  else no "$label: does not read the ledger through String text = $reader();"; fi
  if grep -qE "(^|[^[:alnum:]_])$arr\(\)" <<<"$flat"; then no "$label: still reads through $arr() (a read error reads as empty)"
  else ok "$label: does not read through $arr()"; fi
  null=$(grep -oE 'if\(text==null\)\{[^}]*return;\}' <<<"$flat" | head -n1)
  if [ -z "$null" ]; then no "$label: no if (text == null) { ... return; } (a read failure falls through to the write)"
  else
    nullat=$(offset "$flat" "$null"); writeat=$(offset "$flat" 'StoreInstaller.writeAtomic(')
    if [ "$writeat" -gt 0 ] && [ "$nullat" -lt "$writeat" ]; then ok "$label: returns on text == null before its write"
    else no "$label: the text == null return is not before its writeAtomic"; fi
  fi
  # A3 (the append half): no array-swallowing catch on the append path
  if grep -qF "$SWALLOW" <<<"$flat"; then no "$label: a catch still answers an empty array on the append path"; else ok "$label: no empty-array swallow"; fi
  # A4
  if grep -qF 'unreadable -- reference not recorded (NWP-20261111-24)' <<<"$lit"; then ok "$label: logs the unreadable ledger"
  else no "$label: no 'unreadable -- reference not recorded (NWP-20261111-24)' log line"; fi
  hits=0
  while IFS= read -r line; do
    case "$line" in *NWP-20261111-24*) ;; *) continue ;; esac
    c=$(strip 0 <<<"$line")
    if grep -qE '(^|[^[:alnum:]_])(ticket|note)([^[:alnum:]_]|$)' <<<"$c"; then hits=$((hits+1)); fi
  done <<<"$lit"
  if [ "$hits" -eq 0 ]; then ok "$label: the added log lines name neither ticket nor note"
  else no "$label: $hits added log line(s) print the ticket or the note"; fi
}

# check_reader <label> <body-code-only>
check_reader(){
  local label="$1" code="$2" flat n
  flat=$(tr -d '[:space:]' <<<"$code")
  if grep -qF 'exists()' <<<"$flat"; then ok "$label: tests exists()"; else no "$label: does not test exists() (an absent ledger is not told from an unreadable one)"; fi
  if grep -qF 'KeepOrder.readText(' <<<"$flat"; then ok "$label: reads with KeepOrder.readText("; else no "$label: does not read with KeepOrder.readText("; fi
  if grep -qE 'catch\([^)]*\)\{returnnull;\}' <<<"$flat"; then ok "$label: a read error answers null"; else no "$label: a read error does not answer null"; fi
  n=$(grep -oF 'return"";' <<<"$flat" | wc -l)
  if [ "$n" -eq 1 ]; then ok "$label: one return \"\" (the absent ledger)"; else no "$label: $n return \"\", want exactly 1 (the absent ledger)"; fi
  if grep -qF "$SWALLOW" <<<"$flat"; then no "$label: a catch answers an empty array"; else ok "$label: no empty-array swallow"; fi
}

# check_array <label> <body-code-only> <text-reader>: the render path reads through the text reader.
check_array(){
  local label="$1" code="$2" reader="$3" flat
  flat=$(tr -d '[:space:]' <<<"$code")
  if grep -qF "$reader()" <<<"$flat"; then ok "$label: reads through $reader()"; else no "$label: does not read through $reader()"; fi
  if grep -qE 'File(Reader|InputStream)\(' <<<"$flat"; then no "$label: still opens the ledger itself"; else ok "$label: opens no reader of its own"; fi
}

# extract <file> <name> <signature> <kind>: sets LIT and CODE; rc 1 when a pinned method is absent.
extract(){
  local f="$1" name="$2" sig="$3" kind="$4" r1 r2
  LIT=$(method "$f" 1 "$sig"); r1=$?
  CODE=$(method "$f" 0 "$sig"); r2=$?
  if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ] || [ -z "$LIT" ] || [ -z "$CODE" ]; then
    if [ "$kind" = pinned ]; then no "$name: absent (the text reader is not there)"; return 1; fi
    echo "EXTRACTION FAILED -- $name: its signature moved or its braces do not balance" >&2; exit 2
  fi
  return 0
}

# file|ledger|text reader|array reader|append
LEDGERS="$GATE|nowhere-device-tickets.json|readDeviceTicketsText|readDeviceTickets|appendDeviceTicket
$PROF|nowhere-tickets.json|readTicketsText|readTickets|appendTicket"

echo "== the past-report ledgers are written by temp + rename and kept after a read failure =="
while IFS='|' read -r f ledger reader arr app; do
  # anchors first, so a moved anchor is exit 2 whatever else fails
  extract "$f" "$app" "private void $app\\(String ticket, String note\\) \\{" anchor
  alit="$LIT"; acode="$CODE"
  extract "$f" "$arr" "private org\\.json\\.JSONArray $arr\\(\\) \\{" anchor
  arrcode="$CODE"
  check_append "$app" "$alit" "$acode" "$ledger" "$reader" "$arr"
  check_array "$arr" "$arrcode" "$reader"
  if extract "$f" "$reader" "private String $reader\\(\\) \\{" pinned; then
    check_reader "$reader" "$CODE"
    if grep -qF "\"$ledger\"" <<<"$LIT"; then ok "$reader: reads $ledger"; else no "$reader: does not name $ledger"; fi
  fi
done <<<"$LEDGERS"

echo "== controls: the check itself =="
BAD='private void fake() {
    try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-x"))) { w.write("1"); } catch (Throwable t) {}
}'
GOOD='private void fake2() {
    // a FileWriter( here is prose
    String s = "new java.io.FileWriter(";
    try { StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-x"), s); } catch (Throwable t) {}
}'
fab(){  # <text>: run check_a1 on a fabricated body; its exit status is the FAIL count
  local f lit code
  f=$(mktemp -p "$W") || exit 2
  printf '%s\n' "$1" > "$f"
  lit=$(method "$f" 1 'private void fake2?\(\) \{') && code=$(method "$f" 0 'private void fake2?\(\) \{') || exit 2
  ( FAIL=0; check_a1 fab "$lit" "$code" nowhere-x >/dev/null; exit "$FAIL" )
}
fab "$BAD"; rc=$?
if [ "$rc" -ge 1 ] && [ "$rc" -lt 100 ]; then ok "control: a FileWriter body is flagged"; else no "control: a FileWriter body was NOT flagged (rc=$rc)"; fi
fab "$GOOD"; rc=$?
if [ "$rc" -eq 0 ]; then ok "control: a writeAtomic body with FileWriter( only in prose and a literal passes"; else no "control: the sound body was flagged ($rc)"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "FAIL: --mutate needs python" >&2; exit 2; }

echo "== mutations (each MUST be convicted, and only for its own method) =="
MPASS=0; MFAIL=0
probe(){  # <label> <gate|profile> <python statements calling r(old, new)>
  local label="$1" which="$2" py="$3" src out rc o others g p
  if [ "$which" = gate ]; then src="$GATE"; else src="$PROF"; fi
  out=$(mktemp -p "$W" mut.XXXXXX.java) || exit 2
  "$PY" -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
def r(old, new):
    global s
    if s.count(old) != 1: sys.exit(3)
    s = s.replace(old, new)
exec(sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)' "$src" "$out" "$py" || { MFAIL=$((MFAIL+1)); echo "  FAIL  PROBE BROKEN: $label"; return; }
  if cmp -s "$src" "$out"; then MFAIL=$((MFAIL+1)); echo "  FAIL  PROBE INERT: $label"; return; fi
  g="$GATE"; p="$PROF"
  if [ "$which" = gate ]; then g="$out"; else p="$out"; fi
  o=$(bash "$0" "$g" "$p" 2>/dev/null); rc=$?
  others=$(grep -E '^  FAIL  ' <<<"$o" | grep -vE "^  FAIL  $label:" || true)
  if [ "$rc" -ne 1 ]; then MFAIL=$((MFAIL+1)); echo "  FAIL  NOT CONVICTED: $label (rc=$rc)"
  elif ! grep -qE "^  FAIL  $label:" <<<"$o"; then MFAIL=$((MFAIL+1)); echo "  FAIL  CONVICTED FOR THE WRONG METHOD: $label"
  elif [ -n "$others" ]; then MFAIL=$((MFAIL+1)); echo "  FAIL  ALSO CONVICTED ANOTHER METHOD: $label"
  else MPASS=$((MPASS+1)); echo "  ok    convicted: $label"; fi
}
echo "-- M1 the FileWriter put back in appendDeviceTicket (A1)"
probe appendDeviceTicket gate '
r("""StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-device-tickets.json"), out.toString());""",
  """try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-device-tickets.json"))) { w.write(out.toString()); }""")'
echo "-- M2 appendTicket's null branch falls through to the write (A2)"
probe appendTicket profile '
r("""\"nowhere-tickets.json unreadable -- reference not recorded (NWP-20261111-24)\"); return; }""",
  """\"nowhere-tickets.json unreadable -- reference not recorded (NWP-20261111-24)\"); }""")'
echo "-- M3 the gate's text reader answers \"\" on a read error (A3)"
probe readDeviceTicketsText gate '
r("""try { return KeepOrder.readText(f); } catch (Throwable t) { return null; }""",
  """try { return KeepOrder.readText(f); } catch (Throwable t) { return ""; }""")'
echo "-- M4 the gate's unreadable log line prints the ticket (A4)"
probe appendDeviceTicket gate '
r("""\"nowhere-device-tickets.json unreadable -- reference not recorded (NWP-20261111-24)\");""",
  """\"nowhere-device-tickets.json unreadable -- reference not recorded (NWP-20261111-24): \" + ticket);""")'
echo "$MPASS convicted, $MFAIL failed"
[ "$MFAIL" -eq 0 ] && [ "$MPASS" -eq 4 ] || exit 1
exit 0
