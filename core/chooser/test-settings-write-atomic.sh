#!/usr/bin/env bash
# test-settings-write-atomic.sh [<ProfileActivity.java>] [--mutate] -- the eight per-profile settings writers
# publish their roamed file by StoreInstaller.writeAtomic (temp + rename), never through a truncating FileWriter.
#
# WHY THIS IS COMMITTED. cfgPut (nowhere-config, its body in cfgPutStatic since NWP-20261124-09), setTierOverride (nowhere-media-tiers), writePrefetchMetered
# (nowhere-prefetch-metered), setPinned (nowhere-pins), writeBudgetBytes (nowhere-media-budget), setReclaimIdleMs
# (nowhere-reclaim), writeSealHold (nowhere-seal-hold) and writeSaveMode (nowhere-save-mode) each rewrite a whole file in the roamed chooser's files
# dir. A FileWriter truncates at open and writes at close, so a write that fails at its close (ENOSPC at the flush)
# leaves the file empty or cut, the next seal carries it, and every later sign-in reads the damage: an empty
# nowhere-reclaim reads as the 3-day default (a profile set to "Never" has its on-demand apps re-archived), an
# empty nowhere-config resets every install default, a cut nowhere-pins unpins offline media, an empty
# nowhere-media-budget reads as no limit. writeAtomic leaves the old file whole on any failure.
#
# WHAT IS PINNED, on each method's body found by its exact signature (EXTRACTION FAILED, exit 2, when one moved):
#   * exactly one `StoreInstaller.writeAtomic(` (comments stripped), and the method's own file still named in it
#     (its literal, or CFG_FILE / SealHold.FILE / SaveMode.FILE);
#   * no `FileWriter(` (comments stripped and string literals blanked).
# Controls: setPref (the model caller) passes the same checks, and a fabricated FileWriter body is flagged.
# The behaviour -- a failed open, write, close or rename leaves the target byte for byte -- is executed by
# test-write-atomic-java.sh; this suite pins that the eight callers use it.
#
#   bash test-settings-write-atomic.sh            # the pins
#   bash test-settings-write-atomic.sh --mutate   # ... plus six FileWriter bodies put back, each CONVICTED
#
# Exit: 0 all pass, 1 a check failed, 2 the suite itself could not run.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
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

# check_writer <label> <body-with-literals> <body-code-only> <lit|const> <name>
check_writer(){
  local label="$1" lit="$2" code="$3" kind="$4" name="$5" n found=no
  n=$(grep -oF 'StoreInstaller.writeAtomic(' <<<"$lit" | wc -l)
  if [ "$n" -eq 1 ]; then ok "$label: one StoreInstaller.writeAtomic("; else no "$label: $n StoreInstaller.writeAtomic( calls, want exactly 1"; fi
  case "$kind" in
    lit)   grep -qF "\"$name\"" <<<"$lit" && found=yes ;;
    const) grep -qE "(^|[^[:alnum:]_.])${name//./\\.}([^[:alnum:]_]|$)" <<<"$lit" && found=yes ;;
  esac
  if [ "$found" = yes ]; then ok "$label: names $name"; else no "$label: does not name $name"; fi
  if grep -qE 'FileWriter[[:space:]]*\(' <<<"$code"; then no "$label: still writes through a FileWriter("; else ok "$label: no FileWriter("; fi
}

# name|signature regex|kind|file name
TABLE='cfgPutStatic|static void cfgPutStatic\(android\.content\.Context ctx, String key, String val\) \{|const|CFG_FILE
setTierOverride|private boolean setTierOverride\(String app, String tier\) \{|lit|nowhere-media-tiers
writePrefetchMetered|private boolean writePrefetchMetered\(boolean on\) \{|lit|nowhere-prefetch-metered
setPinned|private boolean setPinned\(String app, boolean on\) \{|lit|nowhere-pins
writeBudgetBytes|private boolean writeBudgetBytes\(long bytes\) \{|lit|nowhere-media-budget
setReclaimIdleMs|private boolean setReclaimIdleMs\(long ms\) \{|lit|nowhere-reclaim
writeSealHold|private boolean writeSealHold\(String v\) \{|const|SealHold.FILE
writeSaveMode|private boolean writeSaveMode\(String v\) \{|const|SaveMode.FILE
setPref|private boolean setPref\(String key, String value\) \{|const|PREFS_FILE'

echo "== the eight settings writers publish by temp + rename =="
while IFS='|' read -r name sig kind file; do
  lit=$(method "$SUT" 1 "$sig"); r1=$?
  code=$(method "$SUT" 0 "$sig"); r2=$?
  if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ] || [ -z "$lit" ] || [ -z "$code" ]; then
    echo "EXTRACTION FAILED -- $name: its signature moved or its braces do not balance" >&2; exit 2
  fi
  label="$name"; [ "$name" = setPref ] && label="control setPref"
  check_writer "$label" "$lit" "$code" "$kind" "$file"
done <<<"$TABLE"

echo "== controls: the check itself =="
BAD='private void fake() {
    try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-x"))) { w.write("1"); } catch (Throwable t) {}
}'
GOOD='private void fake2() {
    // a FileWriter( here is prose
    String s = "new java.io.FileWriter(";
    try { StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-x"), s); } catch (Throwable t) {}
}'
fab(){  # <text>: run check_writer on a fabricated body; its exit status is the FAIL count
  local f lit code
  f=$(mktemp -p "$W") || exit 2
  printf '%s\n' "$1" > "$f"
  lit=$(method "$f" 1 'private void fake2?\(\) \{') && code=$(method "$f" 0 'private void fake2?\(\) \{') || exit 2
  ( FAIL=0; check_writer fab "$lit" "$code" lit nowhere-x >/dev/null; exit "$FAIL" )
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

echo "== mutations (each MUST be convicted) =="
MPASS=0; MFAIL=0
probe(){  # <label> <python statements calling r(old, new)>
  local label="$1" py="$2" out rc
  out=$(mktemp -p "$W" mut.XXXXXX.java) || exit 2
  "$PY" -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
def r(old, new):
    global s
    if s.count(old) != 1: sys.exit(3)
    s = s.replace(old, new)
exec(sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)' "$SUT" "$out" "$py" || { MFAIL=$((MFAIL+1)); echo "  FAIL  PROBE BROKEN: $label"; return; }
  if cmp -s "$SUT" "$out"; then MFAIL=$((MFAIL+1)); echo "  FAIL  PROBE INERT: $label"; return; fi
  bash "$0" "$out" >/dev/null 2>&1; rc=$?
  case "$rc" in
    1) MPASS=$((MPASS+1)); echo "  ok    convicted: $label" ;;
    0) MFAIL=$((MFAIL+1)); echo "  FAIL  NOT CONVICTED: $label" ;;
    *) MFAIL=$((MFAIL+1)); echo "  FAIL  PROBE BROKEN: $label (rc=$rc)" ;;
  esac
}
probe "setReclaimIdleMs back on a FileWriter" '
r("""        try {
            StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-reclaim"), Long.toString(ms));""",
  """        try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-reclaim"))) {
            fw.write(Long.toString(ms));""")'
probe "cfgPut back on a FileWriter" '
r("""        try {
            StoreInstaller.writeAtomic(new java.io.File(ctx.getFilesDir(), CFG_FILE), sb.toString());""",
  """        try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(ctx.getFilesDir(), CFG_FILE))) {
            fw.write(sb.toString());""")'
probe "writeSealHold back on a FileWriter" '
r("""        try {
            StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), SealHold.FILE), val);""",
  """        try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), SealHold.FILE))) {
            w.write(val);""")'
probe "writeSaveMode back on a FileWriter" '
r("""        try {
            StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), SaveMode.FILE), val);""",
  """        try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), SaveMode.FILE))) {
            w.write(val);""")'
probe "setPinned writing piecemeal through a FileWriter again" '
q = chr(39)
r("        StringBuilder sb = new StringBuilder();\n        for (String a : s) sb.append(a).append(" + q + "\\n" + q + ");\n"
  "        try { StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), \"nowhere-pins\"), sb.toString()); }",
  "        try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), \"nowhere-pins\"))) {\n"
  "            for (String a : s) { w.write(a); w.write(\"\\n\"); }\n        }")'
probe "setTierOverride write put back on a FileWriter" '
r("try { StoreInstaller.writeAtomic(f, sb.toString()); }\n        catch (Throwable t) { Log.w(\"NowhereChooser\", \"setTierOverride\"",
  "try (java.io.FileWriter w = new java.io.FileWriter(f)) { w.write(sb.toString()); }\n        catch (Throwable t) { Log.w(\"NowhereChooser\", \"setTierOverride\"")'
echo "$MPASS convicted, $MFAIL failed"
[ "$MFAIL" -eq 0 ] || exit 1
exit 0
