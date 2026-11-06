#!/usr/bin/env bash
# run.sh <Ingest.java> -- NWP-20261112-16: lift Ingest's read-back members verbatim by signature (LOOKUP_FAILED, the
# STEP_* constants, ingestStep, contactPresence, eitherPresent, rawContactId, eventExists, ensureLocalCalendar and the
# syncAdapterAccount it calls), and countsAsAttempt (NWP-20261123-17: only a run that could see the provider spends one
# of a file's tries), compile them against small stubs of the Android classes they touch, and run IngestUnknownCases
# against them and against the source of <Ingest.java> itself. $JAVAC / $JAVA come from the caller
# (core/chooser/test-ingest-unknown-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case or source check failed (the only code that convicts a mutant); 2 = a member did not extract;
# 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/Ingest.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:?run.sh needs W, the temp root of its caller}")
trap 'rm -rf "$D"' EXIT

SIGS=(
  'static int ingestStep('
  'static boolean countsAsAttempt('
  'static Boolean contactPresence('
  'static Boolean eitherPresent('
  'private static long rawContactId('
  'private static Boolean eventExists('
  'private static long ensureLocalCalendar('
  'private static Uri syncAdapterAccount('
)
CONSTS=(
  'static final long LOOKUP_FAILED = '
  'static final int STEP_INSERT = '
)

extract() { # extract <file> <signature-fragment>: from the fragment to the brace that closes its body
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

{
  echo 'import android.content.ContentUris;'
  echo 'import android.content.ContentValues;'
  echo 'import android.content.Context;'
  echo 'import android.database.Cursor;'
  echo 'import android.net.Uri;'
  echo 'import android.provider.CalendarContract;'
  echo 'import android.provider.ContactsContract;'
  echo 'final class Lifted {'
  for c in "${CONSTS[@]}"; do
    line=$(grep -m1 -F -- "$c" "$SRC" || true)
    [ -n "$line" ] || { echo "EXTRACTION FAILED: $c" >&2; exit 2; }
    printf '%s\n' "$line"
  done
  for sig in "${SIGS[@]}"; do
    body=$(extract "$SRC" "$sig") || { echo "EXTRACTION FAILED: $sig" >&2; exit 2; }
    [ -n "$body" ] || { echo "EXTRACTION FAILED: $sig" >&2; exit 2; }
    printf '%s\n\n' "${body#private }"
  done
  echo '}'
} > "$D/Lifted.java"

# ---- the Android stubs: only what the lifted members touch. The resolver's answer per table is programmable
# (THROW, NULL cursor, EMPTY cursor, or a ROW with an id), it counts inserts, and its insert answer is programmable
# too (a created row's uri, null, or a throw: a failed calendar create, NWP-20261123-17).
mkdir -p "$D/stubs/android/content" "$D/stubs/android/database" "$D/stubs/android/net" \
         "$D/stubs/android/provider" "$D/stubs/android/util"
cat > "$D/stubs/android/content/ContentValues.java" <<'JAVA'
package android.content;
import java.util.LinkedHashMap;
import java.util.Map;
public class ContentValues {
  public final Map<String, Object> m = new LinkedHashMap<>();
  public void put(String k, String v) { m.put(k, v); }
  public void put(String k, Integer v) { m.put(k, v); }
  public void put(String k, Long v) { m.put(k, v); }
}
JAVA
cat > "$D/stubs/android/content/ContentUris.java" <<'JAVA'
package android.content;
import android.net.Uri;
public class ContentUris {
  public static long parseId(Uri u) { String s = u.toString(); return Long.parseLong(s.substring(s.lastIndexOf('/') + 1)); }
}
JAVA
cat > "$D/stubs/android/content/ContentResolver.java" <<'JAVA'
package android.content;
import android.database.Cursor;
import android.net.Uri;
import java.util.HashMap;
import java.util.Map;
public class ContentResolver {
  public static final long THROW = -100, NULL = -101, EMPTY = -102; // any other value: one row with that id
  public final Map<String, Long> answer = new HashMap<>();
  public int queries, inserts;
  public Cursor query(Uri u, String[] proj, String sel, String[] args, String order) {
    queries++;
    Long a = answer.get(u.toString());
    if (a == null) throw new IllegalStateException("no answer programmed for " + u);
    if (a == THROW) throw new IllegalStateException("provider restarting");
    if (a == NULL) return null;
    return new Cursor(a == EMPTY ? null : a);
  }
  public Uri insertAnswer = Uri.parse("content://stub/calendars/9");
  public boolean insertThrows;
  public Uri insert(Uri u, ContentValues v) {
    inserts++;
    if (insertThrows) throw new IllegalStateException("create refused");
    return insertAnswer;
  }
}
JAVA
cat > "$D/stubs/android/content/Context.java" <<'JAVA'
package android.content;
public class Context {
  public final ContentResolver r = new ContentResolver();
  public ContentResolver getContentResolver() { return r; }
}
JAVA
cat > "$D/stubs/android/database/Cursor.java" <<'JAVA'
package android.database;
public class Cursor implements AutoCloseable {
  private final Long id;
  public Cursor(Long id) { this.id = id; }
  public boolean moveToFirst() { return id != null; }
  public long getLong(int col) { return id; }
  @Override public void close() {}
}
JAVA
cat > "$D/stubs/android/net/Uri.java" <<'JAVA'
package android.net;
public class Uri {
  private final String s;
  private Uri(String s) { this.s = s; }
  public static Uri parse(String s) { return new Uri(s); }
  public Builder buildUpon() { return new Builder(s); }
  @Override public String toString() { return s; }
  public static final class Builder {
    private final StringBuilder b;
    Builder(String s) { b = new StringBuilder(s); }
    public Builder appendQueryParameter(String k, String v) {
      b.append(b.indexOf("?") < 0 ? '?' : '&').append(k).append('=').append(v); return this;
    }
    public Uri build() { return new Uri(b.toString()); }
  }
}
JAVA
cat > "$D/stubs/android/provider/ContactsContract.java" <<'JAVA'
package android.provider;
import android.net.Uri;
public class ContactsContract {
  public static final String CALLER_IS_SYNCADAPTER = "caller_is_syncadapter";
  public static class RawContacts {
    public static final Uri CONTENT_URI = Uri.parse("content://com.android.contacts/raw_contacts");
    public static final String _ID = "_id", SYNC1 = "sync1", DELETED = "deleted";
  }
}
JAVA
cat > "$D/stubs/android/provider/CalendarContract.java" <<'JAVA'
package android.provider;
import android.net.Uri;
public class CalendarContract {
  public static final String CALLER_IS_SYNCADAPTER = "caller_is_syncadapter";
  public static final String ACCOUNT_TYPE_LOCAL = "LOCAL";
  public static class Calendars {
    public static final Uri CONTENT_URI = Uri.parse("content://com.android.calendar/calendars");
    public static final String _ID = "_id", ACCOUNT_NAME = "account_name", ACCOUNT_TYPE = "account_type",
        NAME = "name", CALENDAR_DISPLAY_NAME = "calendar_displayName", CALENDAR_ACCESS_LEVEL = "calendar_access_level",
        OWNER_ACCOUNT = "ownerAccount", VISIBLE = "visible", SYNC_EVENTS = "sync_events",
        CALENDAR_TIME_ZONE = "calendar_timezone";
    public static final int CAL_ACCESS_OWNER = 700;
  }
  public static class Events {
    public static final Uri CONTENT_URI = Uri.parse("content://com.android.calendar/events");
    public static final String _ID = "_id", CALENDAR_ID = "calendar_id", UID_2445 = "uid2445", DELETED = "deleted";
  }
}
JAVA
cat > "$D/stubs/android/util/Log.java" <<'JAVA'
package android.util;
public class Log {
  public static int w(String tag, String msg) { return 0; }
  public static int w(String tag, String msg, Throwable t) { return 0; }
}
JAVA

cp "$here/IngestUnknownCases.java" "$D/"
mkdir "$D/cls"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/cls" $(find "$D/stubs" -name '*.java') "$D/Lifted.java" \
  "$D/IngestUnknownCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/cls" IngestUnknownCases "$SRC" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
