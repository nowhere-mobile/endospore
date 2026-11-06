#!/usr/bin/env bash
# test-raw-segment-age-java.sh [--mutate] -- an orphaned SMS raw segment is removed 24 h after the gate first saw it,
# run under javac (NWP-20261108-10, Q033 in docs/product-decisions.md, 2026-10-20).
#
# WHY THIS IS COMMITTED. A multipart segment whose siblings never arrive stayed in user 0's mmssms.db across
# power-offs until the framework expired it (docs/backlog.md, "A multipart segment whose siblings never arrive keeps
# its cleartext on user 0, across power-offs, until the framework expires it"). TelScrub.rawSegmentAge records each
# waiting row's id and the time the gate FIRST SAW it, and removes the row 24 h later. The clock is first sight and
# never the row's `date` (the SMSC timestamp: a text held by the network arrives already old), and it is the wall
# clock (a monotonic one restarts at every boot). RawSegmentAge holds those rules (pure, java.lang only) and is
# compiled here with its cases; source checks over TelScrub pin what the cases cannot reach: that sms() runs the
# step after the dispatched-row delete, that it returns outside user 0, the one expiry delete (scoped to deleted = 0
# and one id), that the raw URI constant serves a single read-only query, the one gate file name, and the whole of
# rawSegmentAge, byte for byte against core/chooser/tests/raw-segment-age/rawSegmentAge.reviewed.
#
# Since NWP-20261115-07 (#36, docs/product-decisions.md, 2026-10-22) the scrub stamps and removes only ORPHAN
# segments: RawSegmentAge.orphans holds the rule, and a complete text the framework stored but never dispatched is
# left for the framework. The source checks pin that rawSegmentAge reads the columns the rule needs and hands plan
# the orphans alone.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-raw-segment-age-java.sh            # the cases and the source checks
#   bash test-raw-segment-age-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
unset SKIP_BYTE_PIN   # set only by mutate(), never inherited by a plain run
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RawSegmentAge.java"
TEL="$SRC/TelScrub.java"
CASES="$root/core/chooser/tests/raw-segment-age/RawSegmentAgeCases.java"
REVIEWED="$root/core/chooser/tests/raw-segment-age/rawSegmentAge.reviewed"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
[ -f "$REVIEWED" ] || { echo "FAIL: missing $REVIEWED" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: no perl (the mutants need it)" >&2; exit 2; }

# suite <RawSegmentAge.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RawSegmentAge.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RawSegmentAge.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RawSegmentAgeCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RawSegmentAgeCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip <file>: the code without // comments and /* */ blocks, string and char literals kept whole.
strip() {
  awk '{ out = ""; n = length($0); i = 1; q = ""
    while (i <= n) {
      if (inc) { e = index(substr($0, i), "*/"); if (!e) break; i += e + 1; inc = 0; continue }
      c = substr($0, i, 1)
      if (q != "") { out = out c; if (c == "\\" && i < n) { out = out substr($0, i + 1, 1); i += 2; continue }
                     if (c == q) q = ""; i++; continue }
      if (c == "\"" || c == "\047") { q = c; out = out c; i++; continue }
      d = substr($0, i, 2)
      if (d == "//") break
      if (d == "/*") { inc = 1; i += 2; continue }
      out = out c; i++ }
    print out }' "$1"
}
# first_line <text> <fixed string> -> the first line number holding it, empty when none. Captured, never grep -q.
first_line() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { print NR; exit }'; }
# count <text> <fixed string> -> how many lines hold it.
count() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }
# mbody <text> <fixed signature> -> the method's body, from its signature to the closing brace at four spaces.
mbody() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { on = 1 } on { print } on && /^    }$/ { exit }'; }

# checks <TelScrub.java> -> 0 when every pin holds, 1 otherwise.
checks() {
  local f="$1" code sms rsa bad=0 del call n guard q qc fd orph pl
  [ -f "$f" ] || { echo "  FAIL  no TelScrub.java: $f" >&2; return 1; }
  code=$(strip "$f")
  sms=$(mbody "$code" 'static void sms(Context ctx) {')
  rsa=$(mbody "$code" 'private static void rawSegmentAge(Context ctx) {')
  [ -n "$sms" ] || { echo "  FAIL  sms() not found" >&2; return 1; }
  [ -n "$rsa" ] || { echo "  FAIL  rawSegmentAge() not found" >&2; return 1; }

  del=$(first_line "$sms" 'delete(SMS_RAW_PERMANENT, "deleted = 1 AND date < ?", cutoff)')
  call=$(first_line "$sms" 'rawSegmentAge(ctx);')
  if [ -n "$del" ] && [ -n "$call" ] && [ "$call" -gt "$del" ] && [ "$(count "$sms" 'rawSegmentAge(ctx);')" = 1 ]; then
    echo "  ok    sms() runs rawSegmentAge once, after the dispatched-row delete"
  else
    echo "  FAIL  sms() does not call rawSegmentAge(ctx) once, after the dispatched-row delete" >&2; bad=1
  fi
  guard=$(printf '%s\n' "$rsa" | sed -n '2p' | sed 's/^[[:space:]]*//')
  if [ "$guard" = 'if (android.os.UserHandle.myUserId() != 0) return;' ]; then
    echo "  ok    rawSegmentAge returns outside user 0 before anything else"
  else
    echo "  FAIL  rawSegmentAge's first statement is not the user-0 guard (the record is user 0's)" >&2; bad=1
  fi
  if [ "$(count "$code" 'removed += cr.delete(SMS_RAW_PERMANENT, "_id = ? AND deleted = 0", new String[] { Long.toString(id) });')" = 1 ] \
     && [ "$(count "$code" 'delete(SMS_RAW_PERMANENT')" = 2 ]; then
    echo "  ok    the expiry delete is scoped to one id and deleted = 0, and is the only other permanent delete"
  else
    echo "  FAIL  the expiry delete is not exactly the reviewed one -- a row the framework dispatched meanwhile, or every row, would go" >&2; bad=1
  fi
  n=$(printf '%s\n' "$code" | grep -oE 'SMS_RAW([^_[:alnum:]]|$)' | wc -l | tr -d ' ')
  qc=$(count "$rsa" 'final String[] cols = { "_id", "address", "reference_number", "count", "sequence", "destination_port" };')
  q=$(count "$rsa" 'try (android.database.Cursor c = cr.query(SMS_RAW, cols, "deleted = 0", null, null)) {')
  if [ "$n" = 2 ] && [ "$qc" = 1 ] && [ "$q" = 1 ] && [ "$(count "$code" 'Uri SMS_RAW = Uri.parse("content://sms/raw");')" = 1 ]; then
    echo "  ok    SMS_RAW is declared once and serves one read-only query for waiting rows"
  else
    echo "  FAIL  SMS_RAW appears $n times (want a declaration and the one query for deleted = 0 rows)" >&2; bad=1
  fi
  fd=$(count "$code" 'getFilesDir()')
  if [ "$fd" = 1 ] && [ "$(count "$code" 'new java.io.File(ctx.getFilesDir(), "nowhere-rawseen");')" = 1 ]; then
    echo "  ok    getFilesDir() names the one gate file, nowhere-rawseen"
  else
    echo "  FAIL  getFilesDir() appears $fd times or not as nowhere-rawseen (ci/check-durable-state.py reads one gate name)" >&2; bad=1
  fi
  if [ "$(count "$rsa" 'synchronized (RAW_AGE_LOCK)')" = 1 ] \
     && [ "$(count "$rsa" 'RawSegmentAge.plan(RawSegmentAge.parse(old), waiting, System.currentTimeMillis())')" = 1 ]; then
    echo "  ok    the scan holds the lock and plans on the wall clock"
  else
    echo "  FAIL  the scan lacks its lock or plans on something other than System.currentTimeMillis()" >&2; bad=1
  fi
  orph=$(first_line "$rsa" 'final java.util.List<Long> waiting = RawSegmentAge.orphans(rows);')
  pl=$(first_line "$rsa" 'RawSegmentAge.plan(RawSegmentAge.parse(old), waiting, System.currentTimeMillis())')
  if [ -n "$orph" ] && [ -n "$pl" ] && [ "$orph" -lt "$pl" ] \
     && [ "$(count "$rsa" 'RawSegmentAge.orphans(')" = 1 ] && [ "$(count "$rsa" 'waiting =')" = 1 ] \
     && [ "$(count "$rsa" 'waiting.add(')" = 0 ]; then
    echo "  ok    plan receives RawSegmentAge.orphans(rows) alone: a complete text is never stamped (#36)"
  else
    echo "  FAIL  the list plan receives is not RawSegmentAge.orphans(rows) -- a complete undispatched text would be removed" >&2; bad=1
  fi
  # The whole method is pinned byte for byte, comments included, against the reviewed copy: the pins above cannot
  # reach the record read, the delete loop or the write, and a loop over waiting, a parse of "" or a dropped rename
  # reads as sound to each of them. Any edit to the method fails here and must be reviewed, with that copy updated.
  # SKIP_BYTE_PIN=1 is set by mutate() alone, for the mutants aimed at the pins above: the byte pin would convict
  # every one of them by itself, so with it on they would prove nothing about the pin each is aimed at. A plain run
  # never sets it.
  if [ "${SKIP_BYTE_PIN:-}" != 1 ]; then
    local rbody
    rbody=$(awk '!on && $0 == "    private static void rawSegmentAge(Context ctx) {" { on = 1 } on { print } on && $0 == "    }" { exit }' "$f")
    if [ -f "$REVIEWED" ] && [ -n "$rbody" ] && [ "$rbody" = "$(cat "$REVIEWED")" ]; then
      echo "  ok    rawSegmentAge is exactly the reviewed copy"
    else
      echo "  FAIL  rawSegmentAge differs from core/chooser/tests/raw-segment-age/rawSegmentAge.reviewed -- review the change and update that copy" >&2; bad=1
    fi
  fi
  return "$bad"
}

echo "== the cases =="
suite "$SUT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: RawSegmentAge cases (rc=$rc)" >&2; exit 1; }
echo "== the TelScrub source checks =="
checks "$TEL" || { echo "FAIL: TelScrub source checks" >&2; exit 1; }

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  NOTC=0
  # mutate <label> <cases|checks|pinned> <real file> <perl -0 expression>: the copy must differ, compile, and FAIL.
  # checks runs the source checks WITHOUT the byte pin, so each of those mutants is convicted by the pin it is aimed
  # at; pinned runs them WITH it, for the mutants only the byte pin can reach.
  mutate() {
    local label="$1" kind="$2" file="$3" expr="$4" d m rc
    d=$(mktemp -d -p "$W") || { echo "  FAIL  MUTATION BROKEN (no temp): $label"; NOTC=$((NOTC+1)); return; }
    m="$d/$(basename "$file")"
    if ! perl -0pe "$expr" "$file" > "$m" 2>"$d/err"; then
      echo "  FAIL  MUTATION BROKEN (perl): $label"; NOTC=$((NOTC+1)); rm -rf "$d"; return
    fi
    if cmp -s "$file" "$m"; then echo "  FAIL  MUTATION INERT: $label"; NOTC=$((NOTC+1)); rm -rf "$d"; return; fi
    case "$kind" in
      cases) suite "$m" >/dev/null 2>&1; rc=$? ;;
      checks) SKIP_BYTE_PIN=1 checks "$m" >/dev/null 2>&1; rc=$? ;;
      pinned) SKIP_BYTE_PIN=0 checks "$m" >/dev/null 2>&1; rc=$? ;;
      *) rc=9 ;;
    esac
    case "$kind:$rc" in
      cases:1|checks:1|pinned:1) echo "  ok    convicted: $label" ;;
      cases:0|checks:0|pinned:0) echo "  FAIL  NOT CONVICTED: $label"; NOTC=$((NOTC+1)) ;;
      *) echo "  FAIL  MUTATION BROKEN (rc=$rc, it did not compile or run): $label"; NOTC=$((NOTC+1)) ;;
    esac
    rm -rf "$d"
  }
  mutate "the window shortened to 23 h" cases "$SUT" 's/24L \* 60/23L * 60/'
  mutate "the expiry test is > instead of >=" cases "$SUT" 's/nowMs - first >= WINDOW_MS/nowMs - first > WINDOW_MS/'
  mutate "the clock-moved-back re-stamp removed" cases "$SUT" 's/first == null \|\| first > nowMs/first == null/'
  mutate "vanished ids kept in the record" cases "$SUT" 's/new TreeMap<>\(\);\n(\s+)List<Long> remove/new TreeMap<>(record);\n$1List<Long> remove/'
  mutate "a malformed line read as 0" cases "$SUT" 's/\} catch \(NumberFormatException e\) \{\n(\s+)continue;/} catch (NumberFormatException e) {\n$1id = 0; ms = 0;/'
  mutate "the removed id dropped from the record" cases "$SUT" 's/if \(nowMs - first >= WINDOW_MS\) remove.add\(id\);/if (nowMs - first >= WINDOW_MS) { remove.add(id); next.remove(id); }/'
  mutate "the call removed from sms()" checks "$TEL" 's/\n        rawSegmentAge\(ctx\);//'
  mutate "the call moved before the dispatched-row delete" checks "$TEL" 's/(        try \{ ctx\.getContentResolver\(\)\.delete\(SMS, null, null\); \} catch \(Throwable ignore\) \{\}\n)/$1        rawSegmentAge(ctx);\n/; s/\n        rawSegmentAge\(ctx\);\n    \}/\n    }/'
  mutate "the selection's deleted = 0 dropped" checks "$TEL" 's/"deleted = 0", null, null\)/null, null, null)/'
  mutate "the expiry delete's deleted = 0 dropped" checks "$TEL" 's/"_id = \? AND deleted = 0"/"_id = ?"/'
  mutate "the user-0 guard removed" checks "$TEL" 's/\n        if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;//'
  mutate "a blanket delete through the read-only raw URI" checks "$TEL" 's/(        rawSegmentAge\(ctx\);\n)/        try { ctx.getContentResolver().delete(SMS_RAW, null, null); } catch (Throwable ignore) {}\n$1/'
  mutate "a second getFilesDir() name" checks "$TEL" 's/(final java\.io\.File tmp = new java\.io\.File\()rec\.getParentFile\(\), rec\.getName\(\) \+ "\.tmp"/$1ctx.getFilesDir(), "nowhere-rawseen.tmp"/'
  mutate "the plan on the monotonic clock" checks "$TEL" 's/waiting, System\.currentTimeMillis\(\)\)/waiting, android.os.SystemClock.elapsedRealtime())/'
  mutate "the lock removed" checks "$TEL" 's/synchronized \(RAW_AGE_LOCK\)/synchronized (new Object())/'
  mutate "the delete loop over waiting, not p.remove" pinned "$TEL" 's/for \(long id : p\.remove\)/for (long id : waiting)/'
  mutate "parse(old) becomes parse(\"\")" pinned "$TEL" 's/RawSegmentAge\.parse\(old\)/RawSegmentAge.parse("")/'
  mutate "the write and rename dropped" pinned "$TEL" 's/if \(!ok \|\| !tmp\.renameTo\(rec\)\) tmp\.delete\(\);/tmp.delete();/'
  mutate "a trailing space in rawSegmentAge (the byte pin alone)" pinned "$TEL" 's/(\n                int removed = 0;)\n/$1 \n/'
  mutate "O1 orphans returns every row" cases "$SUT" 's/(for \(Row r : rows\) \{\n)/$1            out.add(r.id);\n/'
  mutate "O2 completeness by row count instead of distinct sequences" cases "$SUT" 's/seqs\.size\(\) == count/g.size() == count/'
  mutate "O3 grouping without reference_number" cases "$SUT" 's/r\.address, r\.referenceNumber, r\.count/r.address, r.count/'
  mutate "O4 grouping without address" cases "$SUT" 's/Arrays\.asList\(r\.address, /Arrays.asList(/'
  mutate "O5 rawSegmentAge hands plan the unfiltered ids" checks "$TEL" 's/final java\.util\.List<Long> waiting = RawSegmentAge\.orphans\(rows\);/final java.util.List<Long> waiting = new java.util.ArrayList<>(); for (RawSegmentAge.Row r : rows) waiting.add(r.id);/'
  mutate "O6 a single-part row counted as an orphan" cases "$SUT" 's/if \(r\.count != null && r\.count == 1\) continue;/if (r.count != null && r.count == 1) { out.add(r.id); continue; }/'
  mutate "O7 the 1..count range check dropped" cases "$SUT" 's/seqs\.size\(\) == count && seqs\.first\(\) == 1 && seqs\.last\(\) == count/seqs.size() == count/'
  mutate "O8 a single-part row run through the multipart rule" cases "$SUT" 's/\n\s+if \(r\.count != null && r\.count == 1\) continue;//'
  if [ "$NOTC" -ne 0 ]; then echo "FAIL: $NOTC mutant(s) not convicted" >&2; exit 1; fi
fi
echo
echo "passed"
