#!/usr/bin/env bash
# test-tel-scrub.sh [<chooser dir>] [--mutate] -- the gate's SMS scrub removes only raw rows the framework is finished
# with (NWP-20260927-10).
#
# WHY THIS IS COMMITTED. The framework keeps each multipart segment in content://sms/raw until the whole text is
# there. A delete on that URI does not remove a row: SmsProvider marks it deleted=1, and the framework reassembles
# only rows with deleted=0. The scrub used to delete that URI with no selection after every text, on every gate
# onResume and at boot, so it marked the segments of any OTHER multipart text still arriving -- which the framework
# had already acknowledged to the network -- and that text never arrived: no record and no notice. Its first fix
# then removed marked rows at once, which throws away the framework's one-hour duplicate record: a network re-send
# of a text is discarded only while its dispatched rows are still there. A blanket delete reads as the obvious way to
# clear residue, and every form of it loses texts, so this pins the scoped form AND the absence of any other literal
# naming the table, across every Java root the NowhereChooser APK compiles: src/ and the vendored MMS parser in mms/
# (core/vendor-common/Android.bp); a Java escape, text block, lone CR or identifier-ignorable character, which would
# spell a literal or a name where no check reads it, fails there outright. A URI assembled at runtime from pieces is
# beyond a source check. Since NWP-20261108-10 (Q033) a row still waiting for its siblings is removed 24 h after the
# gate first saw it (test-raw-segment-age-java.sh pins that); the only other raw literal is its read-only query URI,
# which no delete may use. And the per-boot
# janitor (core/vendor-common/bin/nowhere_gate.sh) must leave the table alone (decided 2026-09-28): it runs at
# sys.boot_completed, when raw can hold texts received during boot and not yet delivered, so its wipe lost them.
# Source-level, in the style of test-owner-mandatory.sh; CI executes it and its --mutate run.
#
#   bash test-tel-scrub.sh            # the invariants
#   bash test-tel-scrub.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; ROOT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) ROOT="$a" ;; esac; done
ROOT="${ROOT:-$(dirname "$0")}"
# The Java roots NowhereChooser compiles (core/vendor-common/Android.bp srcs). A root missing here means the suite is
# pointed at the wrong tree, not that there is nothing to scan.
JAVA_ROOTS="src mms"
for r in $JAVA_ROOTS; do [ -d "$ROOT/$r" ] || { echo "no $r/ under: $ROOT" >&2; exit 2; }; done
SUT="$ROOT/src/com/nowhere/chooser/TelScrub.java"
[ -f "$SUT" ] || { echo "no TelScrub.java under: $ROOT/src" >&2; exit 2; }
GATE="$ROOT/../vendor-common/bin/nowhere_gate.sh"
[ -f "$GATE" ] || { echo "no vendor-common/bin/nowhere_gate.sh beside: $ROOT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# A file's code, without // comments and /* */ or /** */ blocks, so only functional forms count. One pass that steps
# over string and char literals and keeps them, since the checks read inside them: a "//" or "/*" inside one --
# "content://", a MIME type such as "*/*" or "image/*" -- opens no comment. Read as an opener, such a literal blanked
# every line up to the next "*/" and hid a blanket raw delete written there from every check below.
strip(){
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
CODE=$(strip "$SUT")
# ⚠ Every match below reads its input to the end: `grep -c ... >/dev/null` or `grep -o | wc -l`, never `grep -q`.
# Under pipefail, grep -q exits at its first match and the command feeding it can then die of SIGPIPE, which fails the
# whole pipeline -- a pattern that IS there reads as absent. That made this suite's cross-file check pass on the very
# code it exists to reject: the SmsDeliverReceiver mutation below was convicted on one run and passed on the next.
# occ <ERE>: how many times it occurs in TelScrub's code -- occurrences, not lines, so a second use written on the
# same line as the first is counted.
occ(){ printf '%s\n' "$CODE" | grep -oE -- "$1" | wc -l | tr -d ' '; }
# Every literal spelling SmsProvider's UriMatcher resolves to the raw table. The matcher reads Uri.getPathSegments(),
# which percent-decodes and drops empty segments, so "sms//raw", "sms/r%61w" and a "/raw" or "raw/" fragment all
# reach it: a "raw" path segment, its letters plain or percent-escaped, after a slash or opening a string literal,
# and ending the literal or followed by a path, query or fragment delimiter. That is content://sms/raw, a "raw"
# segment appended to an sms URI, and the framework's own permanent-delete idiom (InboundSmsHandler),
# Uri.withAppendedPath(Telephony.Sms.CONTENT_URI, "raw/permanentDelete"). Those are spellings of the URI; a spelling
# of the Java literal itself -- a unicode or octal escape, a text block -- is refused by the last check below.
RAWREF='[/"](r|%72)(a|%61)(w|%77)([/"?#]|$)'

echo "== the raw table is scrubbed only where the framework is finished =="
if printf '%s\n' "$CODE" | grep -cF 'Uri.parse("content://sms/raw/permanentDelete")' >/dev/null; then
  ok "the scrub uses the permanent-delete URI"
else
  no "the scrub no longer uses content://sms/raw/permanentDelete"
fi
if printf '%s\n' "$CODE" | grep -cF 'delete(SMS_RAW_PERMANENT, "deleted = 1 AND date < ?", cutoff)' >/dev/null; then
  ok "it removes only dispatched rows (deleted = 1) past the duplicate window (date < cutoff)"
else
  no "the permanent delete is not scoped to deleted = 1 AND date < cutoff -- it destroys a segment still arriving, or the framework's duplicate record"
fi
# The cutoff is pinned whole, never by a fragment: the one statement that computes it, the name `cutoff` used there
# and at the delete and nowhere else, and the window declared once and read only there. A fragment passes while the
# value the delete compares `date` against is something else -- `(now - W) * 1000`, `now - W / 60`, or `now` with the
# right expression left unused beside it.
if printf '%s\n' "$CODE" | grep -cF 'RAW_DEDUP_WINDOW_MS = 3_600_000L;' >/dev/null \
   && printf '%s\n' "$CODE" | grep -cF 'final String[] cutoff = { Long.toString(System.currentTimeMillis() - RAW_DEDUP_WINDOW_MS) };' >/dev/null \
   && [ "$(occ cutoff)" = 2 ] && [ "$(occ RAW_DEDUP_WINDOW_MS)" = 2 ]; then
  ok "the cutoff is now minus SmsProvider's one-hour window"
else
  no "the cutoff is not now minus one hour -- SmsProvider keeps dispatched rows RAW_MESSAGE_EXPIRE_AGE_MS = 1 h for de-duplication"
fi
N=$(occ SMS_RAW_PERMANENT)
if [ "$N" = 3 ] \
   && printf '%s\n' "$CODE" | grep -cF 'delete(SMS_RAW_PERMANENT, "_id = ? AND deleted = 0", new String[] { Long.toString(id) })' >/dev/null; then
  ok "the permanent-delete URI is declared once and used twice, each use scoped (dispatched rows past the hour; one waiting row past 24 h)"
else
  no "SMS_RAW_PERMANENT appears $N times, not 3, or its second use is not the one-id deleted = 0 delete -- a further use deletes outside the scoped selections"
fi
N=$(occ 'SMS_RAW([^_[:alnum:]]|$)')
if [ "$N" = 2 ] && printf '%s\n' "$CODE" | grep -cF 'query(SMS_RAW, ' >/dev/null \
   && ! printf '%s\n' "$CODE" | grep -E '(delete|update|insert)\(SMS_RAW[^_[:alnum:]]' >/dev/null; then
  ok "the read-only raw URI is declared once and used by one query, never a delete, update or insert"
else
  no "SMS_RAW appears $N times (want 2) or feeds a delete, update or insert -- a delete on it marks every row deleted=1"
fi
N=$(occ "$RAWREF")
if [ "$N" = 2 ] && printf '%s\n' "$CODE" | grep -cF 'Uri.parse("content://sms/raw/permanentDelete")' >/dev/null \
   && printf '%s\n' "$CODE" | grep -cF 'Uri SMS_RAW = Uri.parse("content://sms/raw");' >/dev/null; then
  ok "TelScrub names the raw table only in the permanentDelete literal and the read-only query URI"
else
  no "TelScrub names the raw table other than in the permanentDelete literal and the read-only query URI (names: $N) -- a bare raw delete marks every row"
fi
OTHER=""
while IFS= read -r f; do
  [ "$f" = "$SUT" ] && continue
  if strip "$f" | grep -cE -- "$RAWREF" >/dev/null; then OTHER="$OTHER ${f#"$ROOT"/}"; fi
done < <(for r in $JAVA_ROOTS; do find "$ROOT/$r" -name '*.java'; done | sort)
if [ -z "$OTHER" ]; then
  ok "no other Java source the chooser compiles names the raw table"
else
  no "the raw table is named outside TelScrub:$OTHER"
fi
# Every check above reads a file a line at a time and knows plain string and char literals, nothing else of Java's
# lexing. javac translates a unicode escape before it lexes anything, ends a line at a lone CR as at LF, decodes an
# octal escape inside a literal, reads a text block across lines, and drops an identifier-ignorable character -- a
# C0 control that is not whitespace, DEL, a C1 control, or a format character in the Basic Multilingual Plane
# (U+00AD, U+200B, U+2060, U+FEFF, ...) -- from a name, raw or escaped (javac keeps a supplementary one, such as a
# tag character, in the name; LEXIGN refuses those too, at no cost). So each can spell the raw table or a pinned name where no
# check reads it ("sms/r\u0061w", "sms\57raw", SMS_RAW_PERMANEN\u0054, and SMS_RAW_PERMA\u00ADNENT or
# cut\u200Boff, which javac reads as SMS_RAW_PERMANENT and cutoff), or put live code where the stripper sees a
# comment: "// \u000a delete(...)" compiles the delete. The chooser needs none of them -- its only unicode escapes
# are the seven punctuation marks LEXESC allows, its only octal escape one '\0', and it has no raw control or format
# character -- so any of them in a Java root it compiles fails. A unicode escape counts where javac reads one, after
# an even run of backslashes, comments included. An escape the chooser comes to need is added to LEXESC on purpose.
LEXESC='(?<!\\)(?:\\\\)*\\u+(?!00[bB]7|20(?:1[49cCdD]|2[26]))[0-9a-fA-F]{4}'
LEXIGN='[\x{0}-\x{8}\x{E}-\x{1B}\x{7F}-\x{9F}\p{Cf}]'
# A control that must match. Outside a UTF-8 locale grep -P reads bytes, not characters: \x{7F}-\x{9F} and \p{Cf}
# (as U+00AD) then match UTF-8 continuation bytes, so the check refuses any file with an em dash or a curly quote,
# while it still cannot see U+FEFF (EF BB BF). A grep built without PCRE fails on -P, which the check would read as no
# match, passing every file. -a keeps a NUL inside its line rather than ending it there.
printf 'SMS_RAW_PERMA\357\273\277NENT\n' | LC_ALL=C.UTF-8 grep -acP "$LEXIGN" >/dev/null \
  || { echo "grep -P cannot read Unicode format characters here (it needs PCRE and the C.UTF-8 locale)" >&2; exit 2; }
LEX=""
while IFS= read -r f; do
  if LC_ALL=C grep -acP "$LEXESC" "$f" >/dev/null \
     || LC_ALL=C.UTF-8 grep -acP "$LEXIGN" "$f" >/dev/null \
     || awk '{ c = index($0, "\r") } c && c < length($0) { n++ } END { exit !n }' "$f" \
     || strip "$f" | grep -cE '(^|[^\\])(\\\\)*\\([1-7]|0[0-7])' >/dev/null \
     || strip "$f" | grep -cF '"""' >/dev/null; then LEX="$LEX ${f#"$ROOT"/}"; fi
done < <(for r in $JAVA_ROOTS; do find "$ROOT/$r" -name '*.java'; done | sort)
if [ -z "$LEX" ]; then
  ok "no Java source the chooser compiles uses a spelling these checks cannot read"
else
  no "a unicode escape LEXESC does not allow, a control or format character, an octal escape, text block or lone CR in:$LEX -- javac reads text there these checks do not"
fi

echo
echo "== the per-boot janitor leaves the raw table alone =="
# The janitor's scrub block is pinned byte for byte: every line from `if [ -x /system/bin/nowhere_db_fix ]; then` to
# the `fi` that closes it, comments included, must be exactly the reviewed copy below, which empties every message
# table of mmssms.db but raw (decided 2026-09-28: at sys.boot_completed raw can hold texts not yet delivered). A
# line check cannot parse shell: a brace list, ANSI-C quoting, a continued line or a multi-line quoted word can spell
# raw where no single line shows it, and a comment line placed after a continued call ends that call. So inside the
# block nothing is left to parsing -- no comment filter either, which a `#` behind a form feed or after a continued
# line fools: any edit there, however it is written, fails here and must be reviewed, with this copy updated in the
# same change. The block also carries the `telscrub FAILED` line a failed scrub writes (NWP-20261019-15); the
# three FILE wipes sit in their own loop above it, outside this pin and outside the nowhere_db_fix guard.
JBLOCK=$(awk '!on && $0 == "if [ -x /system/bin/nowhere_db_fix ]; then" { on = 1 } on { print } on && $0 == "fi" { exit }' "$GATE")
JWANT=$(cat <<'EOB'
if [ -x /system/bin/nowhere_db_fix ]; then
  scrub_db() { # $1=db path, $2..=content tables to empty
    local _db _rc _nm _sc
    _db="$1"; shift
    [ -f "$_db" ] || { _ts_absent=$((_ts_absent + 1)); return 0; }
    /system/bin/nowhere_db_fix telscrub "$_db" "$@" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || log -t nowhere_gate "telscrub FAILED rc=$_rc on ${_db#/data/} -- its deleted rows may still be on disk" 2>/dev/null
    if [ "$_rc" -eq 0 ]; then
      _ts_ok=$((_ts_ok + 1))
    else
      _ts_failed=$((_ts_failed + 1))
      _nm=${_db##*/}; _nm=${_nm%.db}
      case "$_db" in */user_de/*) _sc=de ;; *) _sc=ce ;; esac
      _ts_dbs="${_ts_dbs:+$_ts_dbs,}$_nm.$_sc:$_rc"
    fi
    return 0
  }
  for _base in /data/user/0 /data/user_de/0; do
    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \
      sms pdu part addr canonical_addresses threads pending_msgs sr_pending attachments drm words
    scrub_db "$_base/com.android.providers.contacts/databases/calllog.db" calls
    scrub_db "$_base/com.android.providers.contacts/databases/calllog_shadow.db" calls
    # DIA-20260808-01: the telephony stack keeps its own ANALYTICS db, and it is not the message store above --
    # it is a separate file in the phone app's DE storage that nothing has ever touched. It survives a logoff
    # because com.android.phone is singleUser: it runs as user 0 and serves whichever user is in the foreground,
    # so a roamed session's telephony activity is recorded in USER-0 storage and the reap never reaches it.
    # Observed on lynx 2026-08-08: 4 rows of SmsMmsDataLogs and 31 of ServiceStateLogs, e.g.
    #   2026-07-31|SMS Incoming|0|1        2026-08-05|SMS Incoming|1|3
    # -- per-day, per-SIM-slot message counts WITH DIRECTION. No content and no addresses, but it still answers
    # "did the previous owner text, on which SIM, on which days, how much" for anyone who reads the file, which
    # is exactly the behavioural residue the amnesia guarantee exists to deny.
    # DELETE+VACUUM rather than rm: the phone process holds this db open, so unlinking it would leave the app
    # writing to a dead inode -- the same trap the log rewrite had to avoid. Same scrub_db path as everything
    # above, so it inherits the busy_timeout and the freed-page collapse.
    scrub_db "$_base/com.android.phone/databases/telephony_analytics.db" \
      SmsMmsDataLogs ServiceStateLogs CallDataLogs
  done
else
  # Both editions' .mk lists ship nowhere_db_fix, so reaching here means a build-configuration
  # regression. The gate has no log file of its own; this logcat line names the missing tool, the boot line at the
  # end of this script records telscrub=SKIPPED, and either beats the old `command -v sqlite3` behaviour, which
  # skipped this entire janitor on every user build in perfect silence.
  log -t nowhere_gate "telscrub SKIPPED: /system/bin/nowhere_db_fix missing on this build" 2>/dev/null
  _ts=SKIPPED
fi
EOB
)
if [ "$JBLOCK" = "$JWANT" ]; then
  ok "the janitor's scrub block is exactly the reviewed one: every message table of mmssms.db but raw"
else
  no "the janitor's scrub block differs from the reviewed one -- review the change (raw must stay out: at sys.boot_completed it can hold texts not yet delivered) and update this copy"
fi
# Outside that block -- the first region the guard opens; a second region guarded the same way is scanned like any
# other line -- no code line may name raw in any case (SQLite matches table names without regard to case, even
# quoted), or percent-escaped (the provider's UriMatcher decodes one), once whole-line comments are left out,
# continued lines joined and shell quotes and backslashes removed. That covers the ways an ordinary edit would write it. A
# spelling made to get past a line check -- a brace list, ANSI-C quoting, a word or construct spread over lines -- or
# a change that stops the block from running at all is beyond it, as runtime assembly is on the Java side.
N=$(awk '!done && $0 == "if [ -x /system/bin/nowhere_db_fix ]; then" { skip = 1 } !skip { print } skip && $0 == "fi" { skip = 0; done = 1 }' "$GATE" \
    | grep -vE '^[[:space:]]*#' | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta}' | tr -d "'\"\\\\" \
    | grep -ciE '(^|[^[:alnum:]_])(r|%72)(a|%61)(w|%77)([^[:alnum:]_]|$)')
if [ "$N" = 0 ]; then
  ok "no other code line of nowhere_gate.sh names the raw table"
else
  no "nowhere_gate.sh names raw on $N code line(s) outside the scrub block -- the janitor runs before user 0 unlocks and would delete texts not yet delivered"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  # mutate <label> <file under the chooser dir> <sed expression>: the suite must FAIL (exit 1) on a copy of both Java
  # roots and the gate script, laid out as in the tree, with the change made. Any other exit is the harness failing,
  # not a conviction.
  mutate(){
    rm -rf "${M:?}/chooser" "${M:?}/vendor-common"; mkdir -p "$M/chooser" "$M/vendor-common/bin"
    for r in $JAVA_ROOTS; do cp -r "$ROOT/$r" "$M/chooser/$r"; done
    cp "$GATE" "$M/vendor-common/bin/nowhere_gate.sh"
    if ! sed "$3" "$ROOT/$2" > "$M/chooser/$2" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$ROOT/$2" "$M/chooser/$2"; then no "MUTATION INERT: $1"; return; fi
    bash "$0" "$M/chooser" >/dev/null 2>&1
    case $? in
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      1) ok "convicted: $1" ;;
      *) no "MUTATION BROKEN (the suite did not run on it): $1" ;;
    esac
  }
  T=src/com/nowhere/chooser/TelScrub.java
  mutate "a blanket delete through the read-only raw URI" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(SMS_RAW, null, null); } catch (Throwable ignore) {}'
  mutate "the expiry delete unscoped" "$T" \
         's@"_id = ? AND deleted = 0", new String\[\] { Long.toString(id) })@null, null)@'
  R=src/com/nowhere/chooser/SmsDeliverReceiver.java
  mutate "the old blanket delete, which marks every raw row" "$T" \
         's@Uri.parse("content://sms/raw/permanentDelete")@Uri.parse("content://sms/raw")@;s@"deleted = 1 AND date < ?", cutoff)@null, null)@'
  mutate "the duplicate window dropped: marked rows removed at once" "$T" \
         's@"deleted = 1 AND date < ?", cutoff)@"deleted = 1", null)@'
  mutate "the scoped permanent delete replaced by an unscoped one" "$T" \
         's@"deleted = 1 AND date < ?", cutoff)@null, null)@'
  mutate "rows still waiting for their siblings deleted once an hour old" "$T" \
         's@"deleted = 1 AND date < ?"@"date < ?"@'
  mutate "the window shortened to a minute" "$T" \
         's@RAW_DEDUP_WINDOW_MS = 3_600_000L;@RAW_DEDUP_WINDOW_MS = 60_000L;@'
  mutate "the cutoff built from the window but not now minus it" "$T" \
         's@System.currentTimeMillis() - RAW_DEDUP_WINDOW_MS)@System.currentTimeMillis() - RAW_DEDUP_WINDOW_MS / 60)@'
  mutate "the cutoff overwritten on the line that computes it" "$T" \
         's@RAW_DEDUP_WINDOW_MS) };@RAW_DEDUP_WINDOW_MS) }; cutoff[0] = Long.toString(System.currentTimeMillis());@'
  mutate "a second, unscoped permanent delete beside the scoped one" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(SMS_RAW_PERMANENT, null, null); } catch (Throwable ignore) {}'
  mutate "a second, unscoped permanent delete on the scoped one's line" "$T" \
         's@cutoff); } catch (Throwable ignore) {}@cutoff); } catch (Throwable ignore) {} try { ctx.getContentResolver().delete(SMS_RAW_PERMANENT, null, null); } catch (Throwable ignore) {}@'
  mutate "the blanket delete re-added in the AOSP idiom" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(Uri.withAppendedPath(SMS, "raw"), null, null); } catch (Throwable ignore) {}'
  mutate "an unscoped permanent delete in the framework's own idiom" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(Uri.withAppendedPath(SMS, "raw/permanentDelete"), null, null); } catch (Throwable ignore) {}'
  mutate "a blanket raw delete behind a \"*/*\" literal, which a string-blind stripper reads as a comment" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        final String anyType = "*/*"; try { ctx.getContentResolver().delete(Uri.parse("content://sms/raw"), null, null); } catch (Throwable ignore) {}'
  mutate "a blanket raw delete added to SmsDeliverReceiver" "$R" \
         '/TelScrub.sms(app);/a\            app.getContentResolver().delete(android.net.Uri.parse("content://sms/raw"), null, null);'
  mutate "an unscoped permanent delete in the framework's idiom, added to SmsDeliverReceiver" "$R" \
         '/TelScrub.sms(app);/a\            app.getContentResolver().delete(android.net.Uri.withAppendedPath(android.provider.Telephony.Sms.CONTENT_URI, "raw/permanentDelete"), null, null);'
  mutate "a blanket raw delete with the path percent-escaped, added to SmsDeliverReceiver" "$R" \
         '/TelScrub.sms(app);/a\            app.getContentResolver().delete(android.net.Uri.parse("content://sms/r%61w"), null, null);'
  mutate "the same behind a '\"' char literal, which a char-blind stripper reads as opening a string" "$R" \
         '/TelScrub.sms(app);/a\            final boolean dq = "x".charAt(0) == '\''"'\''; final String mime = "image/*"; app.getContentResolver().delete(android.net.Uri.parse("content://sms/raw"), null, null);'
  mutate "a blanket raw delete added to the vendored MMS parser, which the APK also compiles" \
         mms/com/google/android/mms/pdu/PduComposer.java \
         '/mResolver = context.getContentResolver();/a\        mResolver.delete(android.net.Uri.parse("content://sms/raw"), null, null);'
  mutate "a blanket raw delete with a letter unicode-escaped" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(Uri.parse("content://sms/r\\u0061w"), null, null); } catch (Throwable ignore) {}'
  mutate "a blanket raw delete with a letter octal-escaped, added to SmsDeliverReceiver" "$R" \
         '/TelScrub.sms(app);/a\            app.getContentResolver().delete(android.net.Uri.parse("content://sms/\\162aw"), null, null);'
  mutate "a blanket raw delete with its slash octal-escaped" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(Uri.parse("content://sms\\57raw"), null, null); } catch (Throwable ignore) {}'
  mutate "a second, unscoped permanent delete with its name unicode-escaped" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(SMS_RAW_PERMANEN\\u0054, null, null); } catch (Throwable ignore) {}'
  mutate "a blanket raw delete behind \\u000a in a line comment, which javac compiles" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        // tidy \\u000a try { ctx.getContentResolver().delete(Uri.parse("content://sms/raw"), null, null); } catch (Throwable ignore) {}'
  mutate "a blanket raw delete behind a lone CR in a line comment, which javac compiles" "$T" \
         's@cutoff); } catch (Throwable ignore) {}@& // tidy\rtry { ctx.getContentResolver().delete(Uri.parse("content://sms/raw"), null, null); } catch (Throwable ignore) {}@'
  mutate "a blanket raw delete through a text block, whose content:// line the stripper reads as a comment" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(Uri.parse("""\n            content://sms/raw"""), null, null); } catch (Throwable ignore) {}'
  mutate "a second, unscoped permanent delete with a soft hyphen (U+00AD) in its name, which javac drops" "$T" \
         "/SMS_RAW_PERMANENT, \"deleted = 1 AND/a\\        try { ctx.getContentResolver().delete(SMS_RAW_PERMA$(printf '\302\255')NENT, null, null); } catch (Throwable ignore) {}"
  mutate "a second, unscoped permanent delete with a raw control character (U+0001) in its name, which javac drops" "$T" \
         "/SMS_RAW_PERMANENT, \"deleted = 1 AND/a\\        try { ctx.getContentResolver().delete(SMS_RAW_PERMA$(printf '\001')NENT, null, null); } catch (Throwable ignore) {}"
  mutate "a second, unscoped permanent delete with \\u0001 in its name, which javac drops" "$T" \
         '/SMS_RAW_PERMANENT, "deleted = 1 AND/a\        try { ctx.getContentResolver().delete(SMS_RAW_PERMA\\u0001NENT, null, null); } catch (Throwable ignore) {}'
  mutate "the cutoff overwritten through cut\\u200Boff, which javac reads as cutoff" "$T" \
         's@RAW_DEDUP_WINDOW_MS) };@RAW_DEDUP_WINDOW_MS) }; cut\\u200Boff[0] = Long.toString(System.currentTimeMillis());@'
  G=../vendor-common/bin/nowhere_gate.sh
  # Inside the scrub block every change is convicted by the byte-for-byte pin, however it is spelt.
  mutate "raw put back in the boot janitor's table list" "$G" \
         's@^      sms pdu part addr@      sms raw pdu part addr@'
  mutate "a separate boot-janitor delete of raw" "$G" \
         '/^      sms pdu part addr/a\    /system/bin/nowhere_db_fix telscrub "$_base/com.android.providers.telephony/databases/mmssms.db" raw >/dev/null 2>\&1'
  mutate "the boot janitor's other message tables dropped" "$G" \
         's@^      sms pdu part addr canonical_addresses threads pending_msgs sr_pending attachments drm words$@      sms@'
  mutate "the boot janitor's mmssms.db scrub commented out" "$G" \
         's@^    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \\$@    # scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \\@'
  mutate "the boot janitor's mmssms.db scrub made a no-op" "$G" \
         's@^    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \\$@    : scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \\@'
  mutate "a boot-janitor scrub of raw upper-cased, which SQLite matches regardless of case" "$G" \
         '/^      sms pdu part addr/a\    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" RAW'
  mutate "a boot-janitor scrub of raw spelt through shell quotes" "$G" \
         '/^      sms pdu part addr/a\    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" "ra"w'
  mutate "a boot-janitor scrub of raw spelt by brace expansion" "$G" \
         '/^      sms pdu part addr/a\    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" r{a,}w'
  mutate "a boot-janitor scrub of raw spelt with ANSI-C quoting" "$G" \
         "/^      sms pdu part addr/a\\    scrub_db \"\$_base/com.android.providers.telephony/databases/mmssms.db\" \$'\\\\162aw'"
  mutate "a boot-janitor scrub of raw split over a continued line" "$G" \
         '/^      sms pdu part addr/a\
    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" ra\\\
w'
  mutate "a boot-janitor scrub of raw on a line that begins with # inside a multi-line quoted word" "$G" \
         '/^      sms pdu part addr/a\    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" ${_none:+"\
#"} raw'
  mutate "the mmssms.db table list cut off by a comment line after its continued call" "$G" \
         '/^      sms pdu part addr/i\    # a comment line here ends the call above'
  mutate "a boot-janitor scrub of raw behind a form-feed-led #, which the shell reads as a word, not a comment" "$G" \
         '/^      sms pdu part addr/a\    \f# ; scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" raw'
  # Outside it, the plain spellings are convicted by the scan.
  mutate "a janitor wipe of raw added after the scrub block, upper-cased" "$G" \
         '$a\/system/bin/nowhere_db_fix telscrub /data/user_de/0/com.android.providers.telephony/databases/mmssms.db RAW >/dev/null 2>\&1'
  mutate "a janitor content delete of raw added after the scrub block, quoted and percent-escaped" "$G" \
         '$a\content delete --uri "content://sms/r%61w" >/dev/null 2>\&1'
  mutate "a janitor wipe of raw in a second block guarded like the scrub block, after it" "$G" \
         '$a\if [ -x /system/bin/nowhere_db_fix ]; then\
  /system/bin/nowhere_db_fix telscrub /data/user_de/0/com.android.providers.telephony/databases/mmssms.db raw >/dev/null 2>\&1\
fi'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
