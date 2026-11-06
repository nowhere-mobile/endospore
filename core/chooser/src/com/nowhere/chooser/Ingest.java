package com.nowhere.chooser;

import android.content.ContentProviderOperation;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;
import android.provider.ContactsContract;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Web-import ingestion (NWP-20260827-18, docs/web-import.md slice II): turn the staged
 * Documents/Imported/*.vcf and *.ics of a web-created profile into LIVE rows in this roamed user's
 * contacts and calendar providers. Without this the user's contacts arrive as a file they must import by
 * hand -- a gap #102 named and web import closes.
 *
 * This runs IN the roamed user (an "ingest" start of CredentialService at login, the TelIngest shape) for
 * the same reason TelIngest does: a normal app in the target user can query-back VERIFY its own inserts,
 * which the su:s0 worker structurally cannot (DIA-56 -- `content insert` exits 0 even when the provider
 * drops the row; that blindness shipped 15 duplicate SMS once). The daemon serves the file BYTES over the
 * peer-authenticated socket (GET-INGEST) because scoped storage denies us the direct read -- Documents/ is
 * not a media collection -- and root can read the real tree.
 *
 * The completion model, hardened by the NWP-20260827-18 review (every rule below answers a confirmed
 * failure scenario):
 *
 *  - VERIFY LIKE TELINGEST, NOT ONCE: a provider row can vanish AFTER an apparently-successful verified
 *    insert during session bring-up (TelIngest.java:22-30, device-proven), so every entry is re-verified
 *    -- and re-inserted if gone -- across the same {+15s, +45s} passes before anything is marked done.
 *  - THE RECEIPT IS THE RECORD, and it is the ONLY record. A per-file CONTENT-HASH receipt lands in our
 *    own CE files dir, which seals and restores with the profile; a file whose receipt is present is
 *    never ingested again, so contacts the user has since deleted stay deleted.
 *
 *    ⚠ The first cut ALSO renamed the staged file to *.imported as a second, cross-scope signal. That can
 *    never work and was removed (NWP-20260827-21): the login daemon holds READ-ONLY policy on the media
 *    tree (sepolicy nowhere.te grants r_dir_perms/r_file_perms and dac_read_search, not dac_override), so
 *    its rename always failed and INGEST-DONE always answered ERR -- silently, since the rename was only
 *    a "hint". The visible cost was that EVERY login re-ingested. Granting the daemon write access to the
 *    whole of a user's media tree to leave a cosmetic marker is not a trade worth making, so the marker
 *    is gone and the receipt stands alone.
 *
 *    What that gives up: if a receipt is lost to a torn seal (a hard power-off between the ingest and the
 *    next seal), the file is ingested again. The per-entry dedup keys make that an upsert rather than a
 *    duplicate -- but an entry the user had deleted in between would come back. Bounded, rare, and the
 *    honest price of not handing a root daemon write access to every photo on the device.
 *  - RETRIES ARE CAPPED (MAX_TRIES, the TelIngest MAX_TEL_RETRIES posture): a file that cannot reach
 *    fully-verified in 3 login attempts -- unreadable bytes (a UTF-16 export, an HTML error page saved as
 *    .ics), an entry the provider permanently rejects -- is loudly logged each time and then SETTLED:
 *    receipt written, file renamed, terminal. Bounded work, and a partially-failing file cannot resurrect
 *    the user's deletions forever. A run in which any of the file's read-backs, or its calendar lookup,
 *    did not complete does not count toward the cap: the provider did not answer, so the run proves nothing
 *    about the file. A failed calendar create still counts (NWP-20261123-17).
 *  - ZERO PARSED BLOCKS IS A FAILURE, never vacuous success: it burns an attempt and logs, so an
 *    unreadable file is retried (fresh restore, next login) up to the cap instead of being silently
 *    marked imported on first sight.
 *
 * The parsers are a deliberate SUBSET, first-party because the platform's vCard code lives in the Contacts
 * APP, out of reach even platform-signed: vCard 2.1 (quoted-printable + BASE64) / 3.0 / 4.0 covering
 * N/FN/TEL/EMAIL/ADR/ORG/TITLE/NOTE/BDAY/PHOTO, and VEVENT covering
 * SUMMARY/DTSTART/DTEND/DURATION/RRULE/LOCATION/DESCRIPTION/UID/RECURRENCE-ID/STATUS with DATE, UTC and
 * TZID forms (quoted or bare). Nested sub-blocks (VALARM) are excluded before property parsing. A
 * recurring series and its RECURRENCE-ID exceptions share a UID by RFC 5545, so the dedup key is
 * UID#RECURRENCE-ID; the exception inserts as a standalone event (the series still shows the original
 * instance too -- a visible, documented subset cost, never a silent drop). EXDATE IS handled
 * (NWP-20260827-25): the extractor emits it on the parent series for every exception, so dropping it
 * resurrected deleted occurrences. A TZID defined only by the file's own VTIMEZONE is read
 * (NWP-20261020-14) in two shapes: a fixed offset, and a yearly BYMONTH/BYDAY pair of STANDARD and DAYLIGHT
 * rules. Still out of scope: a VTIMEZONE in any other shape (RDATE-only, UNTIL/COUNT, BYMONTHDAY ...),
 * which keeps the device zone; photo URIs; files >= 1 MiB (deferred by the web writer, not on disk at login).
 */
final class Ingest {
    private static final long SETTLE_MS = 20_000;               // let grant/seed/restore churn pass, as TelIngest does
    private static final long[] REVERIFY_MS = {15_000, 45_000}; // the TelIngest bring-up-clobber passes
    private static final int MAX_TRIES = 3;                     // per-file login attempts before SETTLED
    private static final int FETCH_TRIES = 3;                   // GET-INGEST attempts (a seal may hold the daemon busy)
    private static final long FETCH_RETRY_MS = 10_000;
    private static final int MAX_PHOTO_BYTES = 1 << 20;         // an applyBatch parcel must stay under the binder limit
    private static final int MAX_ROWS_PER_KIND = 100;           // TEL/EMAIL/ADR rows per contact, same reason

    private Ingest() {}

    /** One staged file as served by GET-INGEST. */
    private static final class StagedFile {
        String name;
        String body;
        String sha12; // content hash -> the receipt/attempts key (name-independent, stable across restores)
        final List<Entry> entries = new ArrayList<>();
        int parsedBlocks;
        int deliberateSkips; // CANCELLED events -- count as complete, never as failures
        int unknownReads; // this run's read-backs + calendar lookup that did not complete (NWP-20261123-17)
    }

    /** One insertable unit with its dedup key; exists() must answer TRUE before the file completes. */
    private abstract static class Entry {
        final String key;
        Entry(String key) { this.key = key; }
        /** TRUE present; FALSE the query completed and found no row; null UNKNOWN (the query threw or gave no
         *  cursor). Only FALSE may insert (NWP-20261112-16). */
        abstract Boolean exists(Context ctx);
        abstract boolean insert(Context ctx);
        /** Called when exists() is TRUE: fold in what this block carries and the contact lacks.
         *  Additive only. Calendar entries keep this no-op. */
        boolean merge(Context ctx) { return true; }
    }

    static final int STEP_INSERT = 0, STEP_MERGE = 1, STEP_WAIT = 2;

    /** What one read-back answer lets run() do: FALSE (completed, no row) inserts, TRUE merges, null (the query
     *  did not complete) does nothing -- the entry stays unverified and its file unfinished (NWP-20261112-16). */
    static int ingestStep(Boolean present) {
        if (present == null) return STEP_WAIT;
        return present ? STEP_MERGE : STEP_INSERT;
    }

    /** Whether this run spends one of the file's MAX_TRIES. An attempt is a run that could see the provider
     *  and still could not verify. A run the provider did not answer (any read-back of the file, or its
     *  calendar lookup, did not complete) proves nothing about the file: it is retried at the next login
     *  without spending the cap. Zero parsed blocks still counts -- unknownReads is 0 there (NWP-20261123-17). */
    static boolean countsAsAttempt(boolean complete, int unknownReads) {
        return !complete && unknownReads == 0;
    }

    /** Fetch this user's staged vcf/ics bytes from the daemon, parse, insert, re-verify across the
     *  bring-up window, and only then mark files done. Runs on a CredentialService worker thread. */
    static void run(Context ctx) {
        List<String> reply = null;
        for (int a = 0; a < FETCH_TRIES; a++) {
            reply = DaemonSocket.roundTripLines("GET-INGEST\n", 15_000);
            if (!reply.isEmpty()) break;
            android.util.Log.w("NowhereChooser", "ingest: GET-INGEST empty (attempt " + (a + 1) + "/"
                    + FETCH_TRIES + ") -- daemon busy?");
            try { Thread.sleep(FETCH_RETRY_MS); } catch (InterruptedException ignored) { return; }
        }
        if (reply == null || reply.isEmpty()) {
            android.util.Log.w("NowhereChooser", "ingest: GET-INGEST never answered -- giving up this session");
            return;
        }
        if (!reply.get(0).startsWith("OK") || reply.size() < 2) return; // NONE: nothing staged, the common case

        List<StagedFile> files = new ArrayList<>();
        for (int i = 1; i < reply.size(); i++) {
            String[] f = reply.get(i).split(" ");
            if (f.length != 3 || !"F".equals(f[0])) continue;
            try {
                StagedFile sf = new StagedFile();
                byte[] bodyRaw = android.util.Base64.decode(f[2], android.util.Base64.DEFAULT);
                sf.name = new String(android.util.Base64.decode(f[1], android.util.Base64.DEFAULT), "UTF-8");
                sf.body = new String(bodyRaw, "UTF-8");
                sf.sha12 = sha256Hex(bodyRaw).substring(0, 12);
                files.add(sf);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "ingest: undecodable file line", t);
            }
        }
        // Drop everything already settled. The receipt is keyed on the file's CONTENT, so this is stable
        // across re-restores of the same bytes -- and touching a settled file again would resurrect the
        // user's own deletions.
        for (java.util.Iterator<StagedFile> it = files.iterator(); it.hasNext(); ) {
            if (receiptFile(ctx, it.next().sha12).exists()) it.remove();
        }
        if (files.isEmpty()) return;

        ensureIngestGrants(ctx);
        try { Thread.sleep(SETTLE_MS); } catch (InterruptedException ignored) { return; }

        int unknown = 0; // read-backs that did not complete this run (NWP-20261112-16)
        // Pass 1: parse + insert (dedup-checked).
        for (StagedFile sf : files) {
            try {
                String lower = sf.name.toLowerCase(java.util.Locale.ROOT);
                if (lower.endsWith(".vcf")) parseVcfInto(sf);
                else if (lower.endsWith(".ics")) parseIcsInto(ctx, sf);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "ingest: parse " + sf.name, t);
            }
            for (Entry e : sf.entries) {
                try {
                    int step = ingestStep(e.exists(ctx));
                    if (step == STEP_INSERT) e.insert(ctx);
                    else if (step == STEP_MERGE) e.merge(ctx);
                    else { unknown++; sf.unknownReads++; }
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "ingest: insert", t);
                }
            }
        }
        // Re-verify passes: bring-up churn can clobber a verified row (TelIngest's device-proven lesson).
        for (long wait : REVERIFY_MS) {
            try { Thread.sleep(wait); } catch (InterruptedException ignored) { break; }
            for (StagedFile sf : files)
                for (Entry e : sf.entries) {
                    try {
                        int step = ingestStep(e.exists(ctx));
                        if (step == STEP_WAIT) { unknown++; sf.unknownReads++; }
                        else if (step == STEP_INSERT) e.insert(ctx); // a clobbered row comes back; never on an unknown
                    } catch (Throwable t) {
                        android.util.Log.w("NowhereChooser", "ingest: re-insert", t);
                    }
                }
        }
        // Finalize: receipt + rename only when EVERY entry is present now.
        for (StagedFile sf : files) {
            int present = 0;
            for (Entry e : sf.entries) {
                try {
                    Boolean p = e.exists(ctx);
                    if (Boolean.TRUE.equals(p)) present++;
                    else if (p == null) { unknown++; sf.unknownReads++; }
                } catch (Throwable ignore) {}
            }
            boolean complete = sf.parsedBlocks > 0
                    && present == sf.entries.size()
                    && sf.entries.size() + sf.deliberateSkips == sf.parsedBlocks;
            if (complete) {
                android.util.Log.i("NowhereChooser", "ingest: " + sf.name + ": " + present + "/"
                        + sf.parsedBlocks + " entr(ies) verified (" + sf.deliberateSkips
                        + " deliberate skip(s)) in " + android.os.Process.myUserHandle());
                settle(ctx, sf);
                continue;
            }
            if (countsAsAttempt(false, sf.unknownReads)) {
                int tries = bumpTries(ctx, sf.sha12);
                android.util.Log.w("NowhereChooser", "ingest: " + sf.name + " NOT complete (" + present + "/"
                        + sf.entries.size() + " present, " + sf.parsedBlocks + " parsed block(s)) -- attempt "
                        + tries + "/" + MAX_TRIES);
                if (tries >= MAX_TRIES) {
                    android.util.Log.w("NowhereChooser", "ingest: " + sf.name + " SETTLED after " + MAX_TRIES
                            + " attempts -- what imported stays, the rest is in the file itself"
                            + " (Documents/Imported, kept)");
                    settle(ctx, sf); // terminal: bounded work, and no more deletion-resurrecting re-runs
                }
            } else {
                android.util.Log.w("NowhereChooser", "ingest: " + sf.name + " NOT complete (" + present + "/"
                        + sf.entries.size() + " present, " + sf.parsedBlocks + " parsed block(s)) -- attempt not"
                        + " counted: " + sf.unknownReads + " read-back(s) did not complete (NWP-20261123-17)");
            }
        }
        if (unknown > 0)
            android.util.Log.w("NowhereChooser", "ingest: " + unknown + " read-back(s) did not complete -- nothing"
                    + " inserted on them; their files stay unfinished and are retried (NWP-20261112-16)");
    }

    /** Mark this file finished by writing its receipt. The staged file itself is deliberately left where
     *  it is: the user keeps their own .vcf/.ics in Documents/Imported, which is a feature, and the
     *  daemon could not rename it anyway (see the header). */
    private static void settle(Context ctx, StagedFile sf) {
        try {
            new java.io.FileOutputStream(receiptFile(ctx, sf.sha12)).close();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: receipt write", t);
        }
    }

    /** The receipt lives in OUR CE files dir, which seals and restores with the profile (the
     *  nowhere-od-materialised marker pattern). Keyed on CONTENT hash, not name, so a file that is
     *  re-restored or renamed by the user is still recognised as already ingested. */
    private static java.io.File receiptFile(Context ctx, String sha12) {
        return new java.io.File(ctx.getFilesDir(), "nowhere-ingested-" + sha12);
    }

    /** Per-file attempt counter, same CE dir so it roams; returns the incremented count. */
    private static int bumpTries(Context ctx, String sha12) {
        java.io.File f = new java.io.File(ctx.getFilesDir(), "nowhere-ingest-tries-" + sha12);
        int n = 0;
        try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
            byte[] b = new byte[8];
            int r = in.read(b);
            if (r > 0) n = Integer.parseInt(new String(b, 0, r, "UTF-8").trim());
        } catch (Throwable ignore) {}
        n++;
        try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
            out.write(String.valueOf(n).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        } catch (Throwable ignore) {}
        return n;
    }

    /** The chooser is the PROFILE OWNER of the roamed user, so it can self-grant the dangerous
     *  contacts/calendar perms for exactly this user -- the ensureCallLogGrant pattern. Narrower than a
     *  default-permissions XML: user 0's kiosk never gains standing access (the manifest's own posture). */
    private static void ensureIngestGrants(Context ctx) {
        try {
            android.app.admin.DevicePolicyManager dpm =
                    ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm == null) return;
            android.content.ComponentName admin = new android.content.ComponentName(ctx, AdminReceiver.class);
            for (String p : new String[]{ android.Manifest.permission.READ_CONTACTS,
                                          android.Manifest.permission.WRITE_CONTACTS,
                                          android.Manifest.permission.READ_CALENDAR,
                                          android.Manifest.permission.WRITE_CALENDAR }) {
                try {
                    dpm.setPermissionGrantState(admin, ctx.getPackageName(), p,
                            android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "ingest grant " + p, t); }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest ensureIngestGrants", t);
        }
    }

    // ---------------------------------------------------------------- contacts

    private static void parseVcfInto(StagedFile sf) throws java.security.NoSuchAlgorithmException {
        List<String> blocks = splitBlocks(sf.body, "BEGIN:VCARD", "END:VCARD");
        sf.parsedBlocks += blocks.size();
        for (String raw : blocks) {
            // NWP-20260920-01: the key is the CONTACT'S IDENTITY, not the bytes that carried it.
            //
            // It used to be sha256(raw block), which deduplicates only a byte-identical re-import. The
            // import page can stage the same person from TWO sources at once -- a .vcf the user picked and
            // the phone's own export over USB -- and those two never agree byte for byte: different vCard
            // version, different property order, an extra ORG or NOTE. The result was two raw contacts for
            // one person, which Android's aggregation usually hides and never removes.
            //
            // legacyKey is still consulted so a profile whose files were ingested under the old scheme is
            // not re-inserted wholesale if a receipt is ever lost.
            final String legacyKey = sha256Hex(raw.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            final VCardEntry vc = parseVCard(raw);
            final String key = contactIdentityKey(vc, legacyKey);
            sf.entries.add(new Entry(key) {
                @Override Boolean exists(Context ctx) {
                    Boolean p = contactPresence(rawContactId(ctx, key));
                    if (Boolean.TRUE.equals(p) || key.equals(legacyKey)) return p;
                    return eitherPresent(p, contactPresence(rawContactId(ctx, legacyKey)));
                }
                @Override boolean insert(Context ctx) { return insertContact(ctx, vc, key); }
                @Override boolean merge(Context ctx) {
                    long id = rawContactId(ctx, key);
                    if (id < 0 && !key.equals(legacyKey)) id = rawContactId(ctx, legacyKey);
                    return id < 0 || mergeContact(ctx, vc, id);
                }
            });
        }
    }

    /** The dedup key for one contact: WHO it is, not which bytes carried it.
     *
     *  Built from the normalised name plus the SET of normalised phone numbers and e-mail addresses,
     *  and nothing else. ORG, TITLE, NOTE, ADR, BDAY and PHOTO are deliberately excluded: they are the
     *  fields two exporters most often disagree about, and disagreeing about them does not make it a
     *  different person.
     *
     *  ⚠ SUPERSEDED by NWP-20261020-19: "excluded from the key also means discarded" and "the first
     *  source wins outright" no longer hold. A block whose key already exists is merged into that
     *  contact by mergePlan: phones and e-mails are equal by the key, so never re-added; an address, an
     *  organization/title pair, a note or a birthday the contact does not already carry is added; a
     *  photo is added only when the contact has none; a repeated import adds nothing.
     *
     *  ⚠⚠ IT FALLS BACK TO THE RAW-BYTE KEY WHEN THERE IS NO PHONE AND NO E-MAIL, AND THAT IS THE
     *  WHOLE SAFETY ARGUMENT. A name on its own is not an identity -- two different people called
     *  "J Smith" with no contact details would collapse into one, and dropping somebody's contact is a
     *  far worse outcome than leaving a duplicate that Android will usually aggregate anyway. So a
     *  merge requires a shared contact point; without one, nothing is merged.
     *
     *  ⚠ Phone numbers keep their LAST 9 DIGITS ONLY, so +44 7700 900123, 07700 900123 and
     *  00447700900123 are one number. Nine is chosen to be shorter than any national subscriber number
     *  we would otherwise split on, and long enough that two unrelated numbers colliding needs the same
     *  name as well.
     */
    private static String contactIdentityKey(VCardEntry e, String legacyKey)
            throws java.security.NoSuchAlgorithmException {
        java.util.TreeSet<String> points = new java.util.TreeSet<>();
        for (String[] t : e.tels) {
            String d = normalisePhone(t[0]);
            if (!d.isEmpty()) points.add("t:" + d);
        }
        for (String[] m : e.emails) {
            String a = m[0] == null ? "" : m[0].trim().toLowerCase(java.util.Locale.ROOT);
            if (!a.isEmpty()) points.add("e:" + a);
        }
        // No shared contact point is possible, so no merge is safe. See the warning above.
        if (points.isEmpty()) return legacyKey;
        StringBuilder sb = new StringBuilder("v1|").append(normaliseName(e)).append('|');
        for (String p : points) sb.append(p).append(',');
        return sha256Hex(sb.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    /** FN when present, else the N components joined; lower-cased with runs of non-letters collapsed,
     *  so "Smith, John" and "John  SMITH" normalise alike. */
    private static String normaliseName(VCardEntry e) {
        StringBuilder src = new StringBuilder();
        if (e.fn != null) src.append(e.fn);
        if (src.length() == 0 && e.n != null) {
            for (String c : e.n) if (c != null) src.append(c).append(' ');
        }
        java.util.TreeSet<String> words = new java.util.TreeSet<>();
        for (String w : src.toString().toLowerCase(java.util.Locale.ROOT).split("[^\\p{L}\\p{N}]+")) {
            if (!w.isEmpty()) words.add(w);
        }
        // Sorted, so "Smith John" and "John Smith" -- the two orders N and FN disagree about -- match.
        return String.join(" ", words);
    }

    /** Digits only, last 9 kept: the same subscriber written with or without a country code. */
    private static String normalisePhone(String s) {
        if (s == null) return "";
        StringBuilder d = new StringBuilder();
        for (int i = 0; i < s.length(); i++) if (Character.isDigit(s.charAt(i))) d.append(s.charAt(i));
        String v = d.toString();
        return v.length() > 9 ? v.substring(v.length() - 9) : v;
    }

    /** Fields this subset carries. Structured fields keep their vCard component split. */
    private static final class VCardEntry {
        String fn;
        String[] n; // family, given, middle, prefix, suffix
        final List<String[]> tels = new ArrayList<>();   // {number, vcard type params}
        final List<String[]> emails = new ArrayList<>(); // {address, type params}
        final List<String[]> adrs = new ArrayList<>();   // {7 ADR components..., type params}
        String org, title, note, bday;
        byte[] photo;
    }

    private static VCardEntry parseVCard(String raw) {
        VCardEntry e = new VCardEntry();
        for (String[] prop : properties(raw)) {
            String pname = prop[0], params = prop[1], value = prop[2];
            switch (pname) {
                case "FN": e.fn = unescape(value); break;
                case "N": {
                    String[] c = splitStructured(value, 5);
                    e.n = new String[]{ unescape(c[0]), unescape(c[1]), unescape(c[2]), unescape(c[3]), unescape(c[4]) };
                    break;
                }
                case "TEL":
                    if (e.tels.size() < MAX_ROWS_PER_KIND) e.tels.add(new String[]{ unescape(value), params });
                    break;
                case "EMAIL":
                    if (e.emails.size() < MAX_ROWS_PER_KIND) e.emails.add(new String[]{ unescape(value), params });
                    break;
                case "ADR": {
                    if (e.adrs.size() >= MAX_ROWS_PER_KIND) break;
                    String[] c = splitStructured(value, 7);
                    String[] row = new String[8];
                    for (int i = 0; i < 7; i++) row[i] = unescape(c[i]);
                    row[7] = params;
                    e.adrs.add(row);
                    break;
                }
                case "ORG": e.org = unescape(splitStructured(value, 2)[0]); break;
                case "TITLE": e.title = unescape(value); break;
                case "NOTE": e.note = unescape(value); break;
                case "BDAY": e.bday = normalizeDate(value); break;
                case "PHOTO":
                    // Inline base64 only (ENCODING=b / BASE64, or a data: URI); remote photo URIs are
                    // skipped, and an oversized photo is dropped so the applyBatch parcel stays under the
                    // binder transaction limit (a >1 MiB photo would fail the whole contact, forever).
                    try {
                        String up = params.toUpperCase(java.util.Locale.ROOT);
                        String v = value;
                        if (v.startsWith("data:")) { int c = v.indexOf(','); v = c >= 0 ? v.substring(c + 1) : ""; }
                        else if (!up.contains("BASE64") && !up.contains("ENCODING=B")) break;
                        byte[] ph = android.util.Base64.decode(v.replaceAll("\\s", ""), android.util.Base64.DEFAULT);
                        if (ph.length > 0 && ph.length <= MAX_PHOTO_BYTES) e.photo = ph;
                    } catch (Throwable ignore) {}
                    break;
                default: break;
            }
        }
        return e;
    }

    /** rawContactId's answer when the query threw or gave no cursor: not "no row", but no answer at all. */
    static final long LOOKUP_FAILED = -2;

    /** rawContactId's answer as presence (the dedup read-back): an id is TRUE, -1 (the query completed and found
     *  no row) FALSE, anything else -- LOOKUP_FAILED -- null, UNKNOWN (NWP-20261112-16). */
    static Boolean contactPresence(long id) {
        if (id >= 0) return Boolean.TRUE;
        if (id == -1) return Boolean.FALSE;
        return null;
    }

    /** Two keys for one contact (identity + legacy): TRUE if either is, FALSE only if both lookups completed and
     *  found nothing, otherwise UNKNOWN. */
    static Boolean eitherPresent(Boolean a, Boolean b) {
        if (Boolean.TRUE.equals(a) || Boolean.TRUE.equals(b)) return Boolean.TRUE;
        if (Boolean.FALSE.equals(a) && Boolean.FALSE.equals(b)) return Boolean.FALSE;
        return null;
    }

    /** The _ID of the live raw contact carrying this entry key, -1 when the query completed with no row, or
     *  LOOKUP_FAILED when it threw or gave no cursor. */
    private static long rawContactId(Context ctx, String key) {
        try (Cursor c = ctx.getContentResolver().query(ContactsContract.RawContacts.CONTENT_URI,
                new String[]{ ContactsContract.RawContacts._ID },
                ContactsContract.RawContacts.SYNC1 + "=? AND " + ContactsContract.RawContacts.DELETED + "=0",
                new String[]{ key }, null)) {
            if (c == null) return LOOKUP_FAILED;
            return c.moveToFirst() ? c.getLong(0) : -1;
        } catch (Throwable t) {
            return LOOKUP_FAILED;
        }
    }

    /** Lower-cased, trimmed, every run of whitespace one space; null is "". The comparison form for the
     *  merge: two exporters write the same address or note with different case and spacing. */
    static String normValue(String s) {
        if (s == null) return "";
        return s.trim().toLowerCase(java.util.Locale.ROOT).replaceAll("\\s+", " ");
    }

    /** The one-line address the provider shows: the non-empty ADR components joined by ", ". */
    private static String formatAddress(String[] adr) {
        StringBuilder formatted = new StringBuilder();
        for (int i = 0; i < 7; i++)
            if (adr[i] != null && !adr[i].isEmpty()) {
                if (formatted.length() > 0) formatted.append(", ");
                formatted.append(adr[i]);
            }
        return formatted.toString();
    }

    /** Which data rows of an incoming block its (already matched) contact lacks. Pure.
     *
     *  {@code have} maps a kind to the normalised values already on the contact: "adr" (normalised
     *  formatted address), "org" (normValue(company) + "\n" + normValue(title)), "note", "bday" (the
     *  stored START_DATE) and "photo" (the single marker "present"). Returns "adr:<i>" per missing
     *  address, then "org", "note", "bday", "photo", in that order. Additive only, and never a name,
     *  phone or e-mail: those are equal by the identity key. A second identical import plans nothing.
     *
     *  "photo" is the one presence-only kind: a raw contact shows a single photo, so a second photo row
     *  would be a hidden row, the shape the identity key exists to prevent. */
    static List<String> mergePlan(VCardEntry in, Map<String, Set<String>> have) {
        List<String> plan = new ArrayList<>();
        Set<String> haveAdr = have.get("adr");
        for (int i = 0; i < in.adrs.size(); i++) {
            String v = normValue(formatAddress(in.adrs.get(i)));
            if (!v.isEmpty() && (haveAdr == null || !haveAdr.contains(v))) plan.add("adr:" + i);
        }
        if (in.org != null || in.title != null) {
            Set<String> haveOrg = have.get("org");
            if (haveOrg == null || !haveOrg.contains(normValue(in.org) + "\n" + normValue(in.title)))
                plan.add("org");
        }
        if (in.note != null) {
            Set<String> haveNote = have.get("note");
            if (haveNote == null || !haveNote.contains(normValue(in.note))) plan.add("note");
        }
        if (in.bday != null) {
            Set<String> haveBday = have.get("bday");
            if (haveBday == null || !haveBday.contains(in.bday)) plan.add("bday");
        }
        if (in.photo != null) {
            Set<String> havePhoto = have.get("photo");
            if (havePhoto == null || havePhoto.isEmpty()) plan.add("photo");
        }
        return plan;
    }

    /** Merge one block into the raw contact {@code id} that already carries its identity: read the
     *  contact's data rows, plan what it lacks, insert only that in one batch. Logs a count, never a value. */
    private static boolean mergeContact(Context ctx, VCardEntry e, long id) {
        Map<String, Set<String>> have = new java.util.HashMap<>();
        try (Cursor c = ctx.getContentResolver().query(ContactsContract.Data.CONTENT_URI,
                new String[]{ ContactsContract.Data.MIMETYPE, ContactsContract.Data.DATA1,
                              ContactsContract.Data.DATA2, ContactsContract.Data.DATA4 },
                ContactsContract.Data.RAW_CONTACT_ID + "=?", new String[]{ String.valueOf(id) }, null)) {
            if (c == null) {
                android.util.Log.w("NowhereChooser", "ingest: merge query returned no cursor");
                return false;
            }
            while (c.moveToNext()) {
                String mime = c.getString(0), d1 = c.getString(1), d4 = c.getString(3);
                if (ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE.equals(mime)) {
                    have.computeIfAbsent("adr", k -> new java.util.HashSet<>()).add(normValue(d1));
                } else if (ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE.equals(mime)) {
                    have.computeIfAbsent("org", k -> new java.util.HashSet<>())
                            .add(normValue(d1) + "\n" + normValue(d4));
                } else if (ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE.equals(mime)) {
                    have.computeIfAbsent("note", k -> new java.util.HashSet<>()).add(normValue(d1));
                } else if (ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE.equals(mime)
                        && c.getInt(2) == ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY) {
                    have.computeIfAbsent("bday", k -> new java.util.HashSet<>()).add(d1 == null ? "" : d1);
                } else if (ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE.equals(mime)) {
                    have.computeIfAbsent("photo", k -> new java.util.HashSet<>()).add("present");
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: merge query", t);
            return false;
        }
        List<String> plan = mergePlan(e, have);
        if (plan.isEmpty()) return true;
        Uri dataUri = syncAdapter(ContactsContract.Data.CONTENT_URI);
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();
        for (String what : plan) {
            ContentProviderOperation.Builder b = ContentProviderOperation.newInsert(dataUri)
                    .withValue(ContactsContract.Data.RAW_CONTACT_ID, id);
            if (what.startsWith("adr:")) {
                ops.add(fillPostal(b.withValue(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE),
                        e.adrs.get(Integer.parseInt(what.substring(4)))).build());
            } else if (what.equals("org")) {
                ops.add(fillOrganization(b.withValue(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE), e).build());
            } else if (what.equals("note")) {
                ops.add(fillNote(b.withValue(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE), e).build());
            } else if (what.equals("bday")) {
                ops.add(fillBirthday(b.withValue(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE), e).build());
            } else if (what.equals("photo")) {
                ops.add(fillPhoto(b.withValue(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE), e).build());
            }
        }
        try {
            ctx.getContentResolver().applyBatch(ContactsContract.AUTHORITY, ops);
            android.util.Log.i("NowhereChooser", "ingest: merged " + ops.size()
                    + " field(s) into an existing contact");
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: merge applyBatch", t);
            return false;
        }
    }

    // The per-kind value mapping, shared by insertContact (back-reference) and mergeContact (explicit id),
    // so the two writers cannot drift.
    private static ContentProviderOperation.Builder fillPostal(ContentProviderOperation.Builder b, String[] adr) {
        // ADR components: pobox, extended, street, locality, region, postcode, country (+params at [7])
        b.withValue(ContactsContract.CommonDataKinds.StructuredPostal.POBOX, emptyNull(adr[0]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.NEIGHBORHOOD, emptyNull(adr[1]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.STREET, emptyNull(adr[2]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.CITY, emptyNull(adr[3]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.REGION, emptyNull(adr[4]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.POSTCODE, emptyNull(adr[5]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.COUNTRY, emptyNull(adr[6]))
                .withValue(ContactsContract.CommonDataKinds.StructuredPostal.TYPE, homeWorkType(adr[7],
                        ContactsContract.CommonDataKinds.StructuredPostal.TYPE_HOME,
                        ContactsContract.CommonDataKinds.StructuredPostal.TYPE_WORK,
                        ContactsContract.CommonDataKinds.StructuredPostal.TYPE_OTHER));
        String formatted = formatAddress(adr);
        if (!formatted.isEmpty())
            b.withValue(ContactsContract.CommonDataKinds.StructuredPostal.FORMATTED_ADDRESS, formatted);
        return b;
    }

    private static ContentProviderOperation.Builder fillOrganization(ContentProviderOperation.Builder b, VCardEntry e) {
        return b.withValue(ContactsContract.CommonDataKinds.Organization.COMPANY, e.org)
                .withValue(ContactsContract.CommonDataKinds.Organization.TITLE, e.title);
    }

    private static ContentProviderOperation.Builder fillNote(ContentProviderOperation.Builder b, VCardEntry e) {
        return b.withValue(ContactsContract.CommonDataKinds.Note.NOTE, e.note);
    }

    private static ContentProviderOperation.Builder fillBirthday(ContentProviderOperation.Builder b, VCardEntry e) {
        return b.withValue(ContactsContract.CommonDataKinds.Event.START_DATE, e.bday)
                .withValue(ContactsContract.CommonDataKinds.Event.TYPE,
                        ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY);
    }

    private static ContentProviderOperation.Builder fillPhoto(ContentProviderOperation.Builder b, VCardEntry e) {
        return b.withValue(ContactsContract.CommonDataKinds.Photo.PHOTO, e.photo);
    }

    /** Insert one contact as a DEVICE-LOCAL raw contact (null account, the AOSP importer's own choice --
     *  always visible, no authenticator needed) through the sync-adapter URI so the SYNC1 dedup key is
     *  written verbatim. */
    private static boolean insertContact(Context ctx, VCardEntry e, String key) {
        Uri rawUri = syncAdapter(ContactsContract.RawContacts.CONTENT_URI);
        Uri dataUri = syncAdapter(ContactsContract.Data.CONTENT_URI);
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();
        ops.add(ContentProviderOperation.newInsert(rawUri)
                .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
                .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
                .withValue(ContactsContract.RawContacts.SYNC1, key)
                .build());
        if (e.fn != null || e.n != null) {
            ContentProviderOperation.Builder b = data(dataUri,
                    ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE);
            if (e.fn != null)
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, e.fn);
            if (e.n != null) {
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.FAMILY_NAME, emptyNull(e.n[0]));
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.GIVEN_NAME, emptyNull(e.n[1]));
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.MIDDLE_NAME, emptyNull(e.n[2]));
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.PREFIX, emptyNull(e.n[3]));
                b.withValue(ContactsContract.CommonDataKinds.StructuredName.SUFFIX, emptyNull(e.n[4]));
            }
            ops.add(b.build());
        }
        for (String[] tel : e.tels)
            ops.add(data(dataUri, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                    .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, tel[0])
                    .withValue(ContactsContract.CommonDataKinds.Phone.TYPE, telType(tel[1]))
                    .build());
        for (String[] em : e.emails)
            ops.add(data(dataUri, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                    .withValue(ContactsContract.CommonDataKinds.Email.ADDRESS, em[0])
                    .withValue(ContactsContract.CommonDataKinds.Email.TYPE, homeWorkType(em[1],
                            ContactsContract.CommonDataKinds.Email.TYPE_HOME,
                            ContactsContract.CommonDataKinds.Email.TYPE_WORK,
                            ContactsContract.CommonDataKinds.Email.TYPE_OTHER))
                    .build());
        for (String[] adr : e.adrs)
            ops.add(fillPostal(data(dataUri,
                    ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE), adr).build());
        if (e.org != null || e.title != null)
            ops.add(fillOrganization(data(dataUri,
                    ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE), e).build());
        if (e.note != null)
            ops.add(fillNote(data(dataUri, ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE), e).build());
        if (e.bday != null)
            ops.add(fillBirthday(data(dataUri, ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE), e).build());
        if (e.photo != null && e.photo.length > 0)
            ops.add(fillPhoto(data(dataUri, ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE), e).build());
        try {
            ctx.getContentResolver().applyBatch(ContactsContract.AUTHORITY, ops);
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: contact applyBatch", t);
            return false;
        }
    }

    private static ContentProviderOperation.Builder data(Uri dataUri, String mime) {
        return ContentProviderOperation.newInsert(dataUri)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE, mime);
    }

    private static int telType(String params) {
        String p = params == null ? "" : params.toUpperCase(java.util.Locale.ROOT);
        if (p.contains("CELL")) return ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE;
        if (p.contains("FAX"))
            return p.contains("WORK") ? ContactsContract.CommonDataKinds.Phone.TYPE_FAX_WORK
                                      : ContactsContract.CommonDataKinds.Phone.TYPE_FAX_HOME;
        if (p.contains("PAGER")) return ContactsContract.CommonDataKinds.Phone.TYPE_PAGER;
        if (p.contains("WORK")) return ContactsContract.CommonDataKinds.Phone.TYPE_WORK;
        if (p.contains("HOME")) return ContactsContract.CommonDataKinds.Phone.TYPE_HOME;
        return ContactsContract.CommonDataKinds.Phone.TYPE_OTHER;
    }

    private static int homeWorkType(String params, int home, int work, int other) {
        String p = params == null ? "" : params.toUpperCase(java.util.Locale.ROOT);
        if (p.contains("WORK")) return work;
        if (p.contains("HOME")) return home;
        return other;
    }

    // ---------------------------------------------------------------- calendar

    private static void parseIcsInto(Context ctx, StagedFile sf) throws java.security.NoSuchAlgorithmException {
        List<String> blocks = splitBlocks(sf.body, "BEGIN:VEVENT", "END:VEVENT");
        sf.parsedBlocks += blocks.size();
        if (blocks.isEmpty()) return;
        final long calId = ensureLocalCalendar(ctx);
        if (calId < 0) {
            android.util.Log.w("NowhereChooser", "ingest: no local calendar for " + sf.name);
            if (calId == LOOKUP_FAILED) sf.unknownReads++; // the query did not answer: not an attempt (NWP-20261123-17)
            return; // entries stay empty -> incomplete -> retried
        }
        final java.util.Map<String, java.util.TimeZone> vtz = icsVTimeZones(sf.body); // NWP-20261020-14
        for (String raw : blocks) {
            String uid = null, recId = null, status = null;
            for (String[] prop : properties(raw)) {
                if ("UID".equals(prop[0])) uid = unescape(prop[2]);
                else if ("RECURRENCE-ID".equals(prop[0])) recId = prop[2].trim();
                else if ("STATUS".equals(prop[0])) status = prop[2].trim().toUpperCase(java.util.Locale.ROOT);
            }
            if ("CANCELLED".equals(status)) { sf.deliberateSkips++; continue; }
            if (uid == null || uid.isEmpty()) uid = "nowhere-" + sha256Hex(raw.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            // A series master and its exception VEVENTs share one UID by RFC 5545; RECURRENCE-ID is what
            // tells them apart, so it joins the dedup key. The exception inserts standalone (subset cost:
            // the series also shows the original instance) -- visible duplication, never a silent drop.
            final String key = recId == null || recId.isEmpty() ? uid : uid + "#" + recId;
            final String rawF = raw;
            sf.entries.add(new Entry(key) {
                @Override Boolean exists(Context ctx2) { return eventExists(ctx2, calId, key); }
                @Override boolean insert(Context ctx2) { return insertEvent(ctx2, calId, rawF, key, vtz); }
            });
        }
    }

    /** Find or create the device-local "Imported" calendar (ACCOUNT_TYPE_LOCAL through the sync-adapter
     *  URI -- the standard shape for an app-owned local calendar). Returns its id; LOOKUP_FAILED when the
     *  query did not complete (unknown: nothing is created, a failed query is not "no calendar",
     *  NWP-20261112-16, and the run does not count toward the cap, NWP-20261123-17); -1 when the create
     *  failed (a rejection: the run counts). */
    private static long ensureLocalCalendar(Context ctx) {
        try (Cursor c = ctx.getContentResolver().query(CalendarContract.Calendars.CONTENT_URI,
                new String[]{ CalendarContract.Calendars._ID },
                CalendarContract.Calendars.ACCOUNT_TYPE + "=? AND " + CalendarContract.Calendars.NAME + "=?",
                new String[]{ CalendarContract.ACCOUNT_TYPE_LOCAL, "Imported" }, null)) {
            if (c == null) {
                android.util.Log.w("NowhereChooser", "ingest: calendar query gave no cursor -- not creating one");
                return LOOKUP_FAILED;
            }
            if (c.moveToFirst()) return c.getLong(0);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: calendar query -- not creating one", t);
            return LOOKUP_FAILED;
        }
        // Only a completed query that found no row reaches the create.
        try {
            ContentValues v = new ContentValues();
            v.put(CalendarContract.Calendars.ACCOUNT_NAME, "Imported");
            v.put(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL);
            v.put(CalendarContract.Calendars.NAME, "Imported");
            v.put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, "Imported");
            v.put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER);
            v.put(CalendarContract.Calendars.OWNER_ACCOUNT, "Imported");
            v.put(CalendarContract.Calendars.VISIBLE, 1);
            v.put(CalendarContract.Calendars.SYNC_EVENTS, 1);
            v.put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, java.util.TimeZone.getDefault().getID());
            Uri u = ctx.getContentResolver().insert(
                    syncAdapterAccount(CalendarContract.Calendars.CONTENT_URI), v);
            return u == null ? -1 : ContentUris.parseId(u);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: calendar create", t);
            return -1;
        }
    }

    /** TRUE / FALSE when the query completed; null when it threw or gave no cursor (NWP-20261112-16). */
    private static Boolean eventExists(Context ctx, long calId, String key) {
        try (Cursor c = ctx.getContentResolver().query(CalendarContract.Events.CONTENT_URI,
                new String[]{ CalendarContract.Events._ID },
                CalendarContract.Events.CALENDAR_ID + "=? AND " + CalendarContract.Events.UID_2445 + "=? AND "
                        + CalendarContract.Events.DELETED + "=0",
                new String[]{ String.valueOf(calId), key }, null)) {
            if (c == null) return null;
            return c.moveToFirst();
        } catch (Throwable t) {
            return null;
        }
    }

    /** Insert one VEVENT under the given dedup key. Android's own rule decides the end shape: a RECURRING
     *  event carries DURATION, a single one carries DTEND. */
    private static boolean insertEvent(Context ctx, long calId, String raw, String key,
                                       java.util.Map<String, java.util.TimeZone> vtz) {
        String summary = null, location = null, description = null, rrule = null, durProp = null;
        String[] dtStart = null, dtEnd = null; // {value, TZID (unquoted) or "", VALUE=DATE ? "DATE" : ""}
        // EXDATE: the occurrences of a recurring series the user cancelled or moved. There may be SEVERAL
        // EXDATE properties, and each may itself carry a comma-separated list, so they accumulate.
        java.util.List<String> exDates = new java.util.ArrayList<>();
        for (String[] prop : properties(raw)) {
            switch (prop[0]) {
                case "SUMMARY": summary = unescape(prop[2]); break;
                case "LOCATION": location = unescape(prop[2]); break;
                case "DESCRIPTION": description = unescape(prop[2]); break;
                case "RRULE": rrule = prop[2]; break;
                case "DURATION": durProp = prop[2].trim(); break;
                case "DTSTART": dtStart = dateParam(prop); break;
                case "DTEND": dtEnd = dateParam(prop); break;
                case "EXDATE":
                    for (String one : prop[2].split(",")) {
                        String t = one.trim();
                        if (!t.isEmpty()) exDates.add(t);
                    }
                    break;
                default: break;
            }
        }
        if (dtStart == null) return false; // malformed (RFC requires DTSTART) -> a failure, never a skip
        boolean allDay = icsAllDay(dtStart); // NWP-20260903-24: a bare yyyyMMdd is all-day too
        long startMs = parseIcsTime(dtStart, allDay, vtz);
        if (startMs < 0) return false;
        // NWP-20261020-14: DTSTART and DTEND are always computed with the zone icsZone derived (the file's own
        // VTIMEZONE included), so a single event lands at its own instant. EVENT_TIMEZONE is what
        // CalendarProvider re-reads, and it cannot resolve a file's custom TZID, so eventZoneId names an id it
        // can. Only a RECURRING series whose custom zone matches no IANA id ends up expanding in the device
        // zone, as an unresolved TZID always did.
        String tz = allDay ? "UTC" : eventZoneId(icsZone(dtStart[1], vtz), startMs); // NWP-20260903-24
        ContentValues v = new ContentValues();
        v.put(CalendarContract.Events.CALENDAR_ID, calId);
        v.put(CalendarContract.Events.TITLE, summary == null ? "" : summary);
        if (location != null) v.put(CalendarContract.Events.EVENT_LOCATION, location);
        if (description != null) v.put(CalendarContract.Events.DESCRIPTION, description);
        v.put(CalendarContract.Events.DTSTART, startMs);
        v.put(CalendarContract.Events.ALL_DAY, allDay ? 1 : 0);
        v.put(CalendarContract.Events.EVENT_TIMEZONE, tz);
        v.put(CalendarContract.Events.UID_2445, key);
        long endMs = dtEnd != null ? parseIcsTime(dtEnd, icsAllDay(dtEnd), vtz) : -1; // NWP-20260903-24
        long durSec = durProp != null ? parseIcsDuration(durProp) : -1;
        if (endMs < 0 && durSec >= 0) endMs = startMs + durSec * 1000L;
        if (endMs < startMs) endMs = startMs + (allDay ? 86_400_000L : 3_600_000L); // default: a day / an hour
        if (rrule != null && !rrule.isEmpty()) {
            v.put(CalendarContract.Events.RRULE, rrule);
            long secs = (endMs - startMs) / 1000L;
            v.put(CalendarContract.Events.DURATION,
                    durProp != null ? durProp : (allDay ? "P" + Math.max(1, secs / 86_400) + "D" : "P" + secs + "S"));
            // EXDATE suppresses the occurrences the user cancelled or moved. WITHOUT THIS the extractor's
            // whole exception strategy silently inverts: it emits EXDATEs on the parent for every exception
            // row and then SKIPS the cancelled row itself, relying on the parent to blank that slot -- so a
            // dropped EXDATE resurrects a deleted occurrence and shows a moved one at BOTH times. It was
            // being generated and then discarded here by `default: break;`.
            // CalendarProvider2's RecurrenceSet parses both forms the extractor emits (yyyyMMddTHHmmssZ and,
            // for an all-day series, yyyyMMdd), and Events.EXDATE takes them comma-joined.
            if (!exDates.isEmpty()) {
                v.put(CalendarContract.Events.EXDATE, android.text.TextUtils.join(",", exDates));
            }
        } else {
            v.put(CalendarContract.Events.DTEND, endMs);
        }
        try {
            Uri u = ctx.getContentResolver().insert(
                    syncAdapterAccount(CalendarContract.Events.CONTENT_URI), v);
            return u != null;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ingest: event insert", t);
            return false;
        }
    }

    /** {value, TZID (quotes stripped) or "", "DATE" when VALUE=DATE} for a DTSTART/DTEND property. RFC 5545
     *  allows TZID="Europe/Paris" -- keeping the quotes makes TimeZone.getTimeZone silently answer GMT. */
    private static String[] dateParam(String[] prop) {
        String tzid = "", kind = "";
        for (String p : splitParams(prop[1])) {
            String up = p.toUpperCase(java.util.Locale.ROOT);
            if (up.startsWith("TZID=")) {
                tzid = p.substring(5).trim();
                if (tzid.length() >= 2 && tzid.charAt(0) == '"' && tzid.charAt(tzid.length() - 1) == '"')
                    tzid = tzid.substring(1, tzid.length() - 1);
            }
            if (up.equals("VALUE=DATE")) kind = "DATE";
        }
        return new String[]{ prop[2].trim(), tzid, kind };
    }

    /** Resolve an iCalendar TZID, falling back to the DEVICE zone when it does not resolve (NWP-20260903-24).
     *
     *  TimeZone.getTimeZone NEVER throws: an id it does not know silently becomes GMT. Outlook and Exchange
     *  emit WINDOWS zone names (TZID="W. Europe Standard Time"), which no JVM/libcore id table contains -- so a
     *  10:00 Berlin meeting was stored as 10:00Z, rendered at 12:00, and EVENT_TIMEZONE persisted as "GMT" so
     *  the whole recurring series expanded at the wrong hour, permanently. dateParam unquotes the value and
     *  handed it straight in; its own comment shows the quoting half of this trap was already known.
     *
     *  Detecting "did not resolve" is exact rather than heuristic, verified against the JVM: the ONLY inputs
     *  that come back with getID()=="GMT" are the literal "GMT", the literal "Z", and ids that are unknown.
     *  Every other real zone returns its own id -- "UTC", "Etc/GMT", "Zulu", "Universal" and even the custom
     *  form "GMT+05:00" all do -- so none of them is mistaken for a failure.
     *
     *  Windows names are resolved through ICU (NWP-20261019-17): windowsZoneId maps "W. Europe Standard Time"
     *  to "Europe/Berlin" from the CLDR table Android ships, so a Berlin meeting keeps its wall clock on any
     *  device. An id that resolves directly is never sent to it, and "GMT"/"Z" stay GMT.
     *
     *  A TZID that is neither IANA nor Windows is then looked up in `vtz`, the zones icsVTimeZones read out of
     *  the file's own VTIMEZONE blocks (NWP-20261020-14). It comes AFTER both tables, so a file can never
     *  redefine a real zone. What is still floating is a custom TZID with no usable VTIMEZONE (any shape
     *  icsVTimeZones does not read): it falls back to the device zone, i.e. the local time the user typed,
     *  which other clients degrade to as well. It is strictly better than silently asserting GMT. */
    private static java.util.TimeZone icsZone(String id, java.util.Map<String, java.util.TimeZone> vtz) {
        if (id == null || id.trim().isEmpty()) return java.util.TimeZone.getDefault(); // floating time
        java.util.TimeZone z = java.util.TimeZone.getTimeZone(id);
        if (!"GMT".equals(z.getID())) return z; // resolved to a real zone (incl. UTC / Etc/GMT / GMT+05:00)
        String u = id.trim();
        if ("GMT".equalsIgnoreCase(u) || "Z".equalsIgnoreCase(u)) return z; // genuinely GMT, not a failure
        String win = windowsZoneId(u);
        if (win != null) {
            java.util.TimeZone w = java.util.TimeZone.getTimeZone(win);
            if (!"GMT".equals(w.getID())) return w; // ICU's answer must itself resolve, else it is a failure
        }
        java.util.TimeZone c = vtz == null ? null : vtz.get(u);
        if (c != null) return c;
        return java.util.TimeZone.getDefault();
    }

    /** The IANA id for a Windows zone name (CLDR windowsZones, via ICU), or null when the name is not a
     *  Windows zone or ICU is unavailable -- a failure here must degrade to the device-zone fallback, never
     *  throw out of an import. */
    private static String windowsZoneId(String winId) {
        try {
            return android.icu.util.TimeZone.getIDForWindowsID(winId, null);
        } catch (Throwable t) {
            return null;
        }
    }

    /** The zones the file's own VTIMEZONE blocks define, by TZID (NWP-20261020-14). Reads RFC 5545 section 3.6.5
     *  for the two shapes that carry a whole rule: STANDARD only (a fixed offset), and STANDARD plus DAYLIGHT
     *  each with a yearly BYMONTH/BYDAY rule (a SimpleTimeZone in WALL_TIME mode, which is what an iCalendar
     *  DTSTART is: local time in the offset in force before the transition). Where a component repeats the
     *  one with the latest DTSTART is the current rule. Any other shape -- RDATE only, UNTIL/COUNT/BYMONTHDAY/
     *  BYSETPOS, a malformed offset, a component without DTSTART, no TZID -- yields NO entry, so icsZone keeps
     *  its device-zone fallback. Never throws: a malformed block is skipped.
     *
     *  splitBlocks cannot do this: it strips nested sub-blocks, and STANDARD/DAYLIGHT are exactly those. */
    static java.util.Map<String, java.util.TimeZone> icsVTimeZones(String body) {
        java.util.Map<String, java.util.TimeZone> out = new java.util.HashMap<>();
        if (body == null) return out;
        StringBuilder top = null, sub = null;
        String subKind = null;
        List<String> std = new ArrayList<>(), dst = new ArrayList<>();
        for (String line : body.split("\r?\n")) {
            String t = line.trim().toUpperCase(java.util.Locale.ROOT);
            if (top == null) {
                if (t.equals("BEGIN:VTIMEZONE")) { top = new StringBuilder(); std.clear(); dst.clear(); sub = null; }
                continue;
            }
            if (sub != null) {
                if (t.equals("END:" + subKind)) { (subKind.equals("STANDARD") ? std : dst).add(sub.toString()); sub = null; }
                else sub.append(line).append('\n');
            } else if (t.equals("END:VTIMEZONE")) {
                try { vtzAdd(out, top.toString(), std, dst); } catch (Throwable skip) { /* a malformed block yields no entry */ }
                top = null;
            } else if (t.equals("BEGIN:STANDARD") || t.equals("BEGIN:DAYLIGHT")) {
                subKind = t.substring(6);
                sub = new StringBuilder();
            } else top.append(line).append('\n');
        }
        return out;
    }

    /** Build the zone for one VTIMEZONE (its own text, then its STANDARD and DAYLIGHT component texts) and put
     *  it in `out`, or put nothing. */
    private static void vtzAdd(java.util.Map<String, java.util.TimeZone> out, String top, List<String> std, List<String> dst) {
        String tzid = null;
        for (String[] p : properties(top)) {
            if (!"TZID".equals(p[0])) continue;
            tzid = p[2].trim();
            if (tzid.length() >= 2 && tzid.charAt(0) == '"' && tzid.charAt(tzid.length() - 1) == '"')
                tzid = tzid.substring(1, tzid.length() - 1).trim();
        }
        if (tzid == null || tzid.isEmpty()) return;
        String[] s = vtzLatest(std);
        if (s == null) return;
        Integer stdOff = vtzOffsetMs(s[1]);
        if (stdOff == null) return;
        if (dst.isEmpty()) { out.put(tzid, new java.util.SimpleTimeZone(stdOff, tzid)); return; }
        String[] d = vtzLatest(dst);
        if (d == null) return;
        Integer dstOff = vtzOffsetMs(d[1]);
        int[] startRule = vtzRule(d[2]), endRule = vtzRule(s[2]);
        if (dstOff == null || startRule == null || endRule == null) return;
        int saving = dstOff - stdOff;
        if (saving <= 0) return;
        out.put(tzid, new java.util.SimpleTimeZone(stdOff, tzid,
                startRule[0], startRule[1], startRule[2], vtzTimeOfDayMs(d[0]), java.util.SimpleTimeZone.WALL_TIME,
                endRule[0], endRule[1], endRule[2], vtzTimeOfDayMs(s[0]), java.util.SimpleTimeZone.WALL_TIME,
                saving));
    }

    /** {DTSTART, TZOFFSETTO, RRULE or ""} of the component with the latest DTSTART, or null when there is none
     *  or any component lacks a well-formed DTSTART. */
    private static String[] vtzLatest(List<String> texts) {
        String[] best = null;
        for (String text : texts) {
            String dt = null, off = "", rr = "";
            for (String[] p : properties(text)) {
                if ("DTSTART".equals(p[0])) dt = p[2].trim();
                else if ("TZOFFSETTO".equals(p[0])) off = p[2].trim();
                else if ("RRULE".equals(p[0])) rr = p[2].trim();
            }
            if (dt == null || !dt.matches("\\d{8}T\\d{6}")) return null;
            if (best == null || dt.compareTo(best[0]) > 0) best = new String[]{ dt, off, rr };
        }
        return best;
    }

    /** Milliseconds for a +-HHMM or +-HHMMSS UTC offset, or null. */
    private static Integer vtzOffsetMs(String s) {
        if (!s.matches("[+-]\\d{4}(\\d{2})?")) return null;
        int h = Integer.parseInt(s.substring(1, 3)), m = Integer.parseInt(s.substring(3, 5));
        int sec = s.length() == 7 ? Integer.parseInt(s.substring(5, 7)) : 0;
        if (h > 23 || m > 59 || sec > 59) return null; // +0160 is malformed, not 02:00
        int secs = h * 3600 + m * 60 + sec;
        return (s.charAt(0) == '-' ? -secs : secs) * 1000;
    }

    private static int vtzTimeOfDayMs(String dtstart) { // yyyyMMdd'T'HHmmss
        return (Integer.parseInt(dtstart.substring(9, 11)) * 3600 + Integer.parseInt(dtstart.substring(11, 13)) * 60
                + Integer.parseInt(dtstart.substring(13, 15))) * 1000;
    }

    /** {0-based month, day-of-week-in-month (-1 = last), Calendar weekday} for FREQ=YEARLY;BYMONTH=m;BYDAY=nDD
     *  (INTERVAL=1 allowed, any part order), or null for any other rule. */
    private static int[] vtzRule(String rrule) {
        if (rrule == null || rrule.isEmpty()) return null;
        boolean yearly = false;
        int month = -1;
        int[] dayRule = null;
        for (String part : rrule.toUpperCase(java.util.Locale.ROOT).split(";")) {
            int eq = part.indexOf('=');
            if (eq < 0) return null;
            String k = part.substring(0, eq), v = part.substring(eq + 1);
            if (k.equals("FREQ") && v.equals("YEARLY")) yearly = true;
            else if (k.equals("INTERVAL") && v.equals("1")) continue;
            else if (k.equals("BYMONTH") && v.matches("([1-9]|1[0-2])")) month = Integer.parseInt(v) - 1;
            else if (k.equals("BYDAY")) {
                java.util.regex.Matcher m = java.util.regex.Pattern.compile("(-1|[1-4])(SU|MO|TU|WE|TH|FR|SA)").matcher(v);
                if (!m.matches()) return null;
                int nth = "-1".equals(m.group(1)) ? -1 : Integer.parseInt(m.group(1));
                int dow = "SU MO TU WE TH FR SA".indexOf(m.group(2)) / 3 + java.util.Calendar.SUNDAY;
                dayRule = new int[]{ nth, dow };
            } else return null;
        }
        if (!yearly || month < 0 || dayRule == null) return null;
        return new int[]{ month, dayRule[0], dayRule[1] };
    }

    /** The id to store as EVENT_TIMEZONE for `z` (NWP-20261020-14). A zone read from the file's VTIMEZONE is
     *  named by the file's custom TZID, which CalendarProvider cannot resolve. So: z's own id when the platform
     *  knows it; else the device zone's id when it has z's offsets over the 400 days either side of atMs; else
     *  the first IANA-style id with z's raw offset that does; else the device zone's id. */
    static String eventZoneId(java.util.TimeZone z, long atMs) {
        String id = z.getID();
        if (java.util.TimeZone.getTimeZone(id).getID().equals(id)) return id;
        java.util.TimeZone dev = java.util.TimeZone.getDefault();
        if (zonesAgree(z, dev, atMs)) return dev.getID();
        String[] ids = java.util.TimeZone.getAvailableIDs(z.getRawOffset());
        java.util.Arrays.sort(ids);
        for (String cand : ids) {
            if (cand.indexOf('/') < 0 || cand.startsWith("Etc/") || cand.startsWith("SystemV/")) continue;
            if (zonesAgree(z, java.util.TimeZone.getTimeZone(cand), atMs)) return cand;
        }
        return dev.getID();
    }

    /** Do two zones have the same UTC offset at every whole hour from 400 days before to 400 days after atMs? */
    private static boolean zonesAgree(java.util.TimeZone a, java.util.TimeZone b, long atMs) {
        for (long t = atMs - 400L * 86_400_000L; t <= atMs + 400L * 86_400_000L; t += 3_600_000L)
            if (a.getOffset(t) != b.getOffset(t)) return false;
        return true;
    }

    /** Is this DTSTART/DTEND an ALL-DAY value? (NWP-20260903-24)
     *
     *  Two independent readings of the same field had drifted apart: the caller decided all-day from
     *  VALUE=DATE alone, while parseIcsTime treats ANY 8-character value as a date at UTC midnight. A bare
     *  DTSTART:20260901 -- legal RFC 5545, and what several exporters emit -- therefore became a TIMED event
     *  at 00:00Z, i.e. THE PREVIOUS DAY anywhere west of UTC, and then took the 1-hour rather than 24-hour
     *  end fallback and wrote DURATION:P86400S instead of P1D.
     *
     *  One helper, used by BOTH the DTSTART and DTEND sites, so the two readings cannot drift again -- the
     *  DTEND site having the identical bug is what showed that duplicating the test was the real defect. */
    private static boolean icsAllDay(String[] d) {
        return "DATE".equals(d[2]) || d[0].length() == 8;
    }

    /** Epoch millis for an ICS date/date-time, or -1. Forms: yyyyMMdd (allDay, UTC midnight),
     *  yyyyMMdd'T'HHmmss'Z' (UTC), yyyyMMdd'T'HHmmss with TZID or floating (device zone). The end-of-day
     *  form T240000 (old Apple iCal) is normalized to next-day T000000 rather than rejected. */
    private static long parseIcsTime(String[] d, boolean asDate, java.util.Map<String, java.util.TimeZone> vtz) {
        try {
            String val = d[0];
            long dayBump = 0;
            if (val.length() >= 15 && val.regionMatches(9, "240000", 0, 6)) {
                val = val.substring(0, 9) + "000000" + val.substring(15);
                dayBump = 86_400_000L;
            }
            java.util.TimeZone zone;
            String pattern;
            if (asDate || val.length() == 8) {
                pattern = "yyyyMMdd";
                zone = java.util.TimeZone.getTimeZone("UTC");
            } else if (val.endsWith("Z")) {
                pattern = "yyyyMMdd'T'HHmmss'Z'";
                zone = java.util.TimeZone.getTimeZone("UTC");
            } else {
                pattern = "yyyyMMdd'T'HHmmss";
                zone = icsZone(d[1], vtz); // NWP-20260903-24: an unknown TZID must not become GMT
            }
            java.text.SimpleDateFormat f = new java.text.SimpleDateFormat(pattern, java.util.Locale.US);
            f.setTimeZone(zone);
            f.setLenient(false);
            java.util.Date parsed = f.parse(val);
            return parsed == null ? -1 : parsed.getTime() + dayBump;
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Seconds in an RFC 5545 duration (P[n]W | P[n]DT[n]H[n]M[n]S), or -1. */
    private static long parseIcsDuration(String s) {
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("^[+-]?P(?:(\\d+)W)?(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?$")
                .matcher(s.trim());
        if (!m.matches()) return -1;
        // RFC 5545 dur-value needs at least one component, and dur-time at least one after the T (NWP-20261013-34).
        if (m.group(1) == null && m.group(2) == null && m.group(3) == null && m.group(4) == null && m.group(5) == null) return -1;
        if (s.indexOf('T') >= 0 && m.group(3) == null && m.group(4) == null && m.group(5) == null) return -1;
        long sec = 0;
        if (m.group(1) != null) sec += Long.parseLong(m.group(1)) * 604_800L;
        if (m.group(2) != null) sec += Long.parseLong(m.group(2)) * 86_400L;
        if (m.group(3) != null) sec += Long.parseLong(m.group(3)) * 3_600L;
        if (m.group(4) != null) sec += Long.parseLong(m.group(4)) * 60L;
        if (m.group(5) != null) sec += Long.parseLong(m.group(5));
        return s.startsWith("-") ? -1 : sec;
    }

    // ---------------------------------------------------------------- shared text plumbing

    /** Split a file into its BEGIN..END blocks, each returned as the raw text between the markers WITH any
     *  nested sub-blocks removed -- a VALARM inside a VEVENT carries its own SUMMARY/DESCRIPTION/DURATION,
     *  and flat-parsing those overwrote the event's (Google exports put a reminder in nearly every event).
     *  Tolerates CRLF and stray whitespace on marker lines. */
    private static List<String> splitBlocks(String body, String begin, String end) {
        List<String> out = new ArrayList<>();
        String[] lines = body.split("\r?\n");
        StringBuilder cur = null;
        int nested = 0;
        for (String line : lines) {
            String t = line.trim();
            if (t.equalsIgnoreCase(begin)) { cur = new StringBuilder(); nested = 0; continue; }
            if (cur == null) continue;
            if (t.equalsIgnoreCase(end) && nested == 0) {
                if (cur.length() > 0) out.add(cur.toString());
                cur = null;
                continue;
            }
            String up = t.toUpperCase(java.util.Locale.ROOT);
            if (up.startsWith("BEGIN:")) { nested++; continue; }
            if (up.startsWith("END:")) { if (nested > 0) nested--; continue; }
            if (nested == 0) cur.append(line).append('\n');
        }
        return out;
    }

    /** Unfold + decode one block into {NAME, params, value} property triples. Handles standard
     *  space/tab folding, vCard 2.1 quoted-printable soft breaks (trailing '='), QP + CHARSET decoding,
     *  Apple's "item1." group prefixes, and RFC 5545 quoted parameter values (a quoted TZID may contain
     *  the very ':' that would otherwise be taken as the value separator). */
    private static List<String[]> properties(String raw) {
        String[] lines = raw.split("\r?\n");
        List<String> unfolded = new ArrayList<>();
        for (String line : lines) {
            if ((line.startsWith(" ") || line.startsWith("\t")) && !unfolded.isEmpty())
                unfolded.set(unfolded.size() - 1, unfolded.get(unfolded.size() - 1) + line.substring(1));
            else if (!line.isEmpty()) unfolded.add(line);
        }
        List<String[]> out = new ArrayList<>();
        for (int i = 0; i < unfolded.size(); i++) {
            String line = unfolded.get(i);
            int colon = valueColon(line);
            if (colon <= 0) continue;
            String head = line.substring(0, colon);
            String value = line.substring(colon + 1);
            String pname = head, params = "";
            int semi = head.indexOf(';');
            if (semi >= 0) { pname = head.substring(0, semi); params = head.substring(semi + 1); }
            int dot = pname.indexOf('.');
            if (dot >= 0) pname = pname.substring(dot + 1); // strip the "item1." group
            pname = pname.trim().toUpperCase(java.util.Locale.ROOT);
            String up = params.toUpperCase(java.util.Locale.ROOT);
            if (up.contains("QUOTED-PRINTABLE")) {
                // 2.1 soft break: a QP value ending in '=' continues on the NEXT physical line.
                while (value.endsWith("=") && i + 1 < unfolded.size())
                    value = value.substring(0, value.length() - 1) + unfolded.get(++i);
                value = decodeQP(value, charsetOf(up));
            }
            out.add(new String[]{ pname, params, value });
        }
        return out;
    }

    /** Index of the colon separating name+params from the value, skipping colons inside DQUOTEd parameter
     *  values (DTSTART;TZID="(UTC+01:00) Amsterdam...":20260901T100000 -- Outlook emits these). */
    private static int valueColon(String line) {
        boolean quoted = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '"') quoted = !quoted;
            else if (c == ':' && !quoted) return i;
        }
        return -1;
    }

    /** Split a parameter list on ';', honouring DQUOTEd values. */
    private static List<String> splitParams(String params) {
        List<String> out = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < params.length(); i++) {
            char c = params.charAt(i);
            if (c == '"') { quoted = !quoted; cur.append(c); continue; }
            if (c == ';' && !quoted) { out.add(cur.toString()); cur.setLength(0); continue; }
            cur.append(c);
        }
        if (cur.length() > 0) out.add(cur.toString());
        return out;
    }

    private static String charsetOf(String upperParams) {
        for (String p : upperParams.split(";"))
            if (p.startsWith("CHARSET=")) return p.substring(8);
        return "UTF-8";
    }

    private static String decodeQP(String s, String charset) {
        try {
            java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '=' && i + 2 < s.length()) {
                    try {
                        bo.write(Integer.parseInt(s.substring(i + 1, i + 3), 16));
                        i += 2;
                        continue;
                    } catch (NumberFormatException ignore) {
                        // not =XX -- fall through and keep the literal '='
                    }
                }
                bo.write(String.valueOf(c).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            return new String(bo.toByteArray(), charset);
        } catch (Throwable t) {
            return s;
        }
    }

    /** Split a structured (';'-separated) value into exactly n components, honouring backslash escapes. */
    private static String[] splitStructured(String value, int n) {
        String[] out = new String[n];
        java.util.Arrays.fill(out, "");
        StringBuilder cur = new StringBuilder();
        int idx = 0;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '\\' && i + 1 < value.length()) { cur.append(c).append(value.charAt(++i)); continue; }
            if (c == ';') {
                if (idx < n) out[idx] = cur.toString();
                idx++;
                cur.setLength(0);
                continue;
            }
            cur.append(c);
        }
        if (idx < n) out[idx] = cur.toString();
        return out;
    }

    /** RFC 6350 text unescaping: \n, \N, \, \; \\ . */
    private static String unescape(String s) {
        if (s == null || s.indexOf('\\') < 0) return s == null ? null : s.trim();
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                char nx = s.charAt(++i);
                if (nx == 'n' || nx == 'N') b.append('\n');
                else b.append(nx);
            } else b.append(c);
        }
        return b.toString().trim();
    }

    /** "19871230" / "1987-12-30" / "--1230" (no year) -> the contacts Event date form. */
    private static String normalizeDate(String v) {
        String s = v.trim();
        if (s.matches("\\d{8}"))
            return s.substring(0, 4) + "-" + s.substring(4, 6) + "-" + s.substring(6, 8);
        if (s.matches("--\\d{4}"))
            return "--" + s.substring(2, 4) + "-" + s.substring(4, 6);
        return s;
    }

    private static String emptyNull(String s) { return s == null || s.isEmpty() ? null : s; }

    /** The generic CALLER_IS_SYNCADAPTER decoration (contacts: account stays null = device-local). */
    private static Uri syncAdapter(Uri base) {
        return base.buildUpon()
                .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true")
                .build();
    }

    /** The calendar flavour: CALLER_IS_SYNCADAPTER plus the local account pair the provider requires. */
    private static Uri syncAdapterAccount(Uri base) {
        return base.buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, "Imported")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
                .build();
    }

    private static String sha256Hex(byte[] in) throws java.security.NoSuchAlgorithmException {
        byte[] d = java.security.MessageDigest.getInstance("SHA-256").digest(in);
        StringBuilder b = new StringBuilder(d.length * 2);
        for (byte x : d) b.append(Character.forDigit((x >> 4) & 0xf, 16)).append(Character.forDigit(x & 0xf, 16));
        return b.toString();
    }
}
