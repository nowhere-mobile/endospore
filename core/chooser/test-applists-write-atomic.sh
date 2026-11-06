#!/usr/bin/env bash
# test-applists-write-atomic.sh [<ProfileActivity.java>] [--mutate] -- the app lists and records the Profile screen
# rewrites publish their roamed file by StoreInstaller.writeAtomic (temp + rename), never through a truncating FileWriter.
#
# WHY THIS IS COMMITTED. appendTicket (nowhere-tickets.json), captureAppList (nowhere-apps.list), recordInferredOrphan
# and captureAppDrops (nowhere-apporphan.list, nowhere-appkeepcode.list, nowhere-appdrop.list), captureAppCode
# (nowhere-appcode.list) and captureArchivedMeta (nowhere-appmeta/<pkg>/meta) each rewrite a whole file in the roamed
# chooser files dir. A FileWriter truncates at open and writes at close, so a write that fails at its close (ENOSPC at
# the flush on a nearly full phone) leaves the file empty or cut, and the logoff seals it: roamd's #apps seal finds
# fewer kept packages than the profile keeps in a cut nowhere-appcode.list, and a cut nowhere-apps.list makes the next
# sign-in provision only the launchable apps its surviving prefix names. writeAtomic leaves the old file whole.
#
# WHAT IS PINNED, on each method's body found by its exact signature (EXTRACTION FAILED, exit 2, when one moved):
#   * no `FileWriter(` (comments stripped, string literals blanked);
#   * `StoreInstaller.writeAtomic(` exactly as many times as the method writes files, each naming its own file
#     (the literal, or the File variable declared as new java.io.File(getFilesDir(), "<literal>")).
# Controls: setPref (the model caller) passes the same checks, and a fabricated FileWriter body is flagged.
# The behaviour -- a failed open, write, close or rename leaves the target byte for byte -- is executed by
# test-write-atomic-java.sh; this suite pins that the six callers use it.
#
#   bash test-applists-write-atomic.sh            # the pins
#   bash test-applists-write-atomic.sh --mutate   # ... plus six FileWriter writes put back, each CONVICTED alone
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

# check_writer <label> <body-with-literals> <body-code-only> <count> <targets>
# targets: ';'-separated, whitespace-free first arguments of writeAtomic; `id=lit` means the identifier id, declared in
# the body as new java.io.File(getFilesDir(), "lit").
check_writer(){
  local label="$1" lit="$2" code="$3" count="$4" targets="$5" n flat got want t id name decl
  if grep -qE 'FileWriter[[:space:]]*\(' <<<"$code"; then no "$label: still writes through a FileWriter("; else ok "$label: no FileWriter("; fi
  n=$(grep -oF 'StoreInstaller.writeAtomic(' <<<"$lit" | wc -l)
  if [ "$n" -eq "$count" ]; then ok "$label: $n StoreInstaller.writeAtomic("; else no "$label: $n StoreInstaller.writeAtomic( calls, want exactly $count"; fi
  flat=$(tr -d '[:space:]' <<<"$lit")
  got=$(grep -oE 'StoreInstaller\.writeAtomic\([^;]*\);' <<<"$flat" | sed -E 's/^StoreInstaller\.writeAtomic\((.*),[^,]*\);$/\1/' | sort | paste -sd';')
  want=""
  for t in ${targets//;/ }; do
    case "$t" in *=*) name="${t%%=*}" ;; *) name="$t" ;; esac
    want="$want$name
"
  done
  want=$(sort <<<"${want%$'\n'}" | paste -sd';')
  if [ "$got" = "$want" ]; then ok "$label: writes $want"; else no "$label: writeAtomic targets $got, want $want"; fi
  for t in ${targets//;/ }; do
    case "$t" in *=*) ;; *) continue ;; esac
    id="${t%%=*}"; name="${t#*=}"
    decl="java.io.File$id=newjava.io.File(getFilesDir(),\"$name\");"
    if grep -qF -- "$decl" <<<"$flat"; then ok "$label: $id is $name"; else no "$label: $id is not new java.io.File(getFilesDir(), \"$name\")"; fi
  done
}

# label|signature regex|writeAtomic calls|targets
TABLE='appendTicket|private void appendTicket\(String ticket, String note\) \{|1|newjava.io.File(getFilesDir(),"nowhere-tickets.json")
captureAppList|private void captureAppList\(\) \{|1|newjava.io.File(getFilesDir(),"nowhere-apps.list")
recordInferredOrphan|private void recordInferredOrphan\(String pkg\) \{|1|newjava.io.File(getFilesDir(),"nowhere-apporphan.list")
captureAppDrops|private void captureAppDrops\(\) \{|3|codeOut=nowhere-appkeepcode.list;orphanOut=nowhere-apporphan.list;out=nowhere-appdrop.list
captureAppCode|private void captureAppCode\(\) \{|1|out=nowhere-appcode.list
captureArchivedMeta|static void captureArchivedMeta\(android\.content\.Context ctx, android\.content\.pm\.PackageManager pm, String pkg, long vc\) \{|1|newjava.io.File(dir,"meta")
setPref|private boolean setPref\(String key, String value\) \{|1|newjava.io.File(getFilesDir(),PREFS_FILE)'

echo "== the six app-list and record writers publish by temp + rename =="
while IFS='|' read -r name sig count targets; do
  lit=$(method "$SUT" 1 "$sig"); r1=$?
  code=$(method "$SUT" 0 "$sig"); r2=$?
  if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ] || [ -z "$lit" ] || [ -z "$code" ]; then
    echo "EXTRACTION FAILED -- $name: its signature moved or its braces do not balance" >&2; exit 2
  fi
  label="$name"; [ "$name" = setPref ] && label="control setPref"
  check_writer "$label" "$lit" "$code" "$count" "$targets"
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
  ( FAIL=0; check_writer fab "$lit" "$code" 1 'newjava.io.File(getFilesDir(),"nowhere-x")' >/dev/null; exit "$FAIL" )
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
probe(){  # <label> <python statements calling r(old, new)>
  local label="$1" py="$2" out rc o others
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
  o=$(bash "$0" "$out" 2>/dev/null); rc=$?
  others=$(grep -E '^  FAIL  ' <<<"$o" | grep -vE "^  FAIL  $label:" || true)
  if [ "$rc" -ne 1 ]; then MFAIL=$((MFAIL+1)); echo "  FAIL  NOT CONVICTED: $label (rc=$rc)"
  elif ! grep -qE "^  FAIL  $label:" <<<"$o"; then MFAIL=$((MFAIL+1)); echo "  FAIL  CONVICTED FOR THE WRONG METHOD: $label"
  elif [ -n "$others" ]; then MFAIL=$((MFAIL+1)); echo "  FAIL  ALSO CONVICTED ANOTHER METHOD: $label"
  else MPASS=$((MPASS+1)); echo "  ok    convicted: $label"; fi
}
probe appendTicket '
r("""StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-tickets.json"), out.toString());""",
  """try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-tickets.json"))) { w.write(out.toString()); }""")'
probe captureAppList '
r("""StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-apps.list"), sb.toString());""",
  """try (java.io.FileWriter fw = new java.io.FileWriter(getFilesDir() + "/nowhere-apps.list")) { fw.write(sb.toString()); }""")'
probe recordInferredOrphan '
r("""StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-apporphan.list"), sb.toString());""",
  """try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(getFilesDir(), "nowhere-apporphan.list"))) { fw.write(sb.toString()); }""")'
probe captureAppDrops '
r("""StoreInstaller.writeAtomic(out, sb.toString());
            android.util.Log.i("NowhereChooser", "captureAppDrops: """,
  """try (java.io.FileWriter fw = new java.io.FileWriter(out)) { fw.write(sb.toString()); }
            android.util.Log.i("NowhereChooser", "captureAppDrops: """)'
probe captureAppCode '
r("""StoreInstaller.writeAtomic(out, sb.toString());
                android.util.Log.i("NowhereChooser", "captured app CODE""",
  """try (java.io.FileWriter fw = new java.io.FileWriter(out)) { fw.write(sb.toString()); }
                android.util.Log.i("NowhereChooser", "captured app CODE""")'
probe captureArchivedMeta '
r("""StoreInstaller.writeAtomic(new java.io.File(dir, "meta"), meta.toString());""",
  """try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(dir, "meta"))) { fw.write(meta.toString()); }""")'
echo "$MPASS convicted, $MFAIL failed"
[ "$MFAIL" -eq 0 ] && [ "$MPASS" -eq 6 ] || exit 1
exit 0
