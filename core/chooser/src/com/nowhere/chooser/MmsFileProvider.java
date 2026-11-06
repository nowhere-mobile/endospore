package com.nowhere.chooser;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;

/**
 * #150 P1b: the write target for SmsManager.downloadMultimediaMessage. The framework's MmsService (in the
 * com.android.phone process, uid 1001) downloads the M-Retrieve.conf body over the SIM's MMS APN and writes
 * it into a content:// Uri we hand it -- it CANNOT be a file:// path (a foreign process can't open our
 * app-private files, and file:// Uris are banned in intents), so we expose one app-private staging file per
 * transaction through this minimal provider. The gate grants com.android.phone temporary R/W on the specific
 * Uri right before the download and revokes it after; the provider is exported=false so nothing else reaches
 * it.
 *
 * The staging file lives in the app cache (RAM-backed on our builds is not guaranteed, so the MMS worker
 * unlinks it as soon as it has parsed the PDU -- amnesia posture: no MMS body lingers at rest on user 0).
 * Path traversal is impossible: we serve only a sanitized basename under the fixed mms/ cache subdir.
 */
public final class MmsFileProvider extends ContentProvider {

    static final String AUTHORITY = "com.nowhere.chooser.mms";

    /** The staging dir for in-flight MMS bodies (created lazily). */
    static File stagingDir(android.content.Context ctx) {
        File d = new File(ctx.getCacheDir(), "mms");
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();
        return d;
    }

    /** content://com.nowhere.chooser.mms/<name> for a staging file basename. */
    static Uri uriFor(String name) {
        return new Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(name).build();
    }

    private File resolve(Uri uri) {
        if (getContext() == null) return null;
        String seg = uri.getLastPathSegment();
        if (seg == null || seg.isEmpty()) return null;
        // basename only -- reject any path separators / traversal so we can never open outside mms/.
        if (seg.indexOf('/') >= 0 || seg.indexOf('\\') >= 0 || seg.contains("..")) return null;
        return new File(stagingDir(getContext()), seg);
    }

    @Override public boolean onCreate() { return true; }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws java.io.FileNotFoundException {
        File f = resolve(uri);
        if (f == null) throw new java.io.FileNotFoundException("bad mms uri: " + uri);
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode == null ? "r" : mode));
    }

    // The MmsService only needs openFile; the rest are inert (no query surface, no CRUD).
    @Override public Cursor query(Uri u, String[] p, String s, String[] a, String o) { return null; }
    @Override public String getType(Uri u) { return "application/vnd.wap.mms-message"; }
    @Override public Uri insert(Uri u, ContentValues v) { return null; }
    @Override public int delete(Uri u, String s, String[] a) {
        File f = resolve(u);
        return (f != null && f.delete()) ? 1 : 0;
    }
    @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
}
