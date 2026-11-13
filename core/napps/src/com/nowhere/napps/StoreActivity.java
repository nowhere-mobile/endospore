package com.nowhere.napps;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.os.IBinder;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.nowhere.chooser.INowhereStore;

/**
 * nApps — the storefront, as its OWN app (DIA-20260818-08, closes #747).
 *
 * WHY A SEPARATE PACKAGE. It already had its own launcher icon, but Settings > Apps enumerates PACKAGES, so
 * an activity inside com.nowhere.chooser could never appear there as its own app however it was labelled.
 *
 * WHY IT OWNS NO DATA PATH. The login daemon pins the first peer's appId and rejects any other
 * (SO_PEERCRED trust-on-first-use, audit #2 / DIA-20260618-08). Teaching it to trust two packages would have
 * bought a Settings row by weakening that, so this app holds no socket, no INTERNET permission and no
 * install authority: it binds com.nowhere.chooser/.StoreService and asks. The chooser is still the only
 * package on the socket, and the install still happens where the privileged permission already lives.
 *
 * There is NO in-screen "Back" link (#74c): this is a launcher-entered app, so leaving it is the system Back
 * button, exactly like any other app.
 */
public class StoreActivity extends Activity {

    // The palette, restated rather than shared -- this APK deliberately depends on the chooser for DATA ONLY, so a
    // resource/classpath dependency would undo the separation. NappsLook holds both sets; applyLook() picks one in
    // onCreate, before the first view (NWP-20261117-31).
    static int BG     = NappsLook.DARK.bg;
    static int INK    = NappsLook.DARK.ink;
    static int MUTED  = NappsLook.DARK.muted;
    static int ACCENT = NappsLook.DARK.accent;
    static int WARN   = NappsLook.DARK.warn;

    private static final int MATCH = LinearLayout.LayoutParams.MATCH_PARENT;
    private static final int WRAP  = LinearLayout.LayoutParams.WRAP_CONTENT;

    private final java.util.Map<String, Bitmap> iconCache = new java.util.concurrent.ConcurrentHashMap<>();

    private INowhereStore store;
    private boolean bound;
    private LinearLayout list;
    private TextView status, headroom;
    private EditText search;
    private String pendingQuery = "";
    private boolean indexAsked; // REFRESH-INDEX once per activity (NWP-20261103-14)

    private final ServiceConnection conn = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName n, IBinder b) {
            store = INowhereStore.Stub.asInterface(b);
            bound = true;
            refreshIndexOnce();
            loadHeadroom();
            reload(pendingQuery);
        }
        @Override public void onServiceDisconnected(ComponentName n) {
            store = null;
            bound = false;
            // The chooser died or was updated. Say so plainly instead of rendering an empty catalog, which
            // reads as "there are no apps" -- a different and wrong statement.
            runOnUiThread(() -> setStatus("Lost contact with the profile service. Reopen nApps to try again."));
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        // NWP-20261117-31: the gate's one device-wide look (docs/product-decisions.md, 2026-10-29), from the Global
        // setting the gate mirrors it to. A Settings.Global read is data: no socket, no permission. The light framework
        // theme goes in before super.onCreate, so the search field and its cursor follow it. A failed read is dark.
        boolean light = false;
        try {
            light = NappsLook.light(android.provider.Settings.Global.getString(getContentResolver(), NappsLook.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("nApps", "look not read, dark: " + t);
        }
        if (light) setTheme(android.R.style.Theme_Material_Light_NoActionBar);
        super.onCreate(b);
        applyLook(light);
        setContentView(buildUi());
        Intent i = new Intent();
        i.setComponent(new ComponentName("com.nowhere.chooser", "com.nowhere.chooser.StoreService"));
        if (!bindService(i, conn, Context.BIND_AUTO_CREATE)) {
            setStatus("Couldn't reach the profile service.");
        }
    }

    /** NWP-20261117-31: the five colour fields from the chosen set, and for light the system bars in the bg with dark
     *  icons. Dark changes no bar. Each bar call is guarded, as ChooserActivity.applyGateBars: a bar call must never
     *  break the store. Once, in onCreate, before the first view. */
    private void applyLook(boolean light) {
        NappsLook p = light ? NappsLook.LIGHT : NappsLook.DARK;
        BG     = p.bg;
        INK    = p.ink;
        MUTED  = p.muted;
        ACCENT = p.accent;
        WARN   = p.warn;
        if (!light) return;
        android.view.Window w = getWindow();
        try { w.setStatusBarColor(p.bg); } catch (Throwable ignore) {}
        try { w.setNavigationBarColor(p.bg); } catch (Throwable ignore) {}
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            try {
                int m = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                        | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                w.getInsetsController().setSystemBarsAppearance(m, m);
            } catch (Throwable ignore) {}
        }
    }

    @Override
    protected void onDestroy() {
        if (bound) {
            try { unbindService(conn); } catch (Throwable ignore) {}
            bound = false;
        }
        super.onDestroy();
    }

    private View buildUi() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.VERTICAL);
        ll.setBackgroundColor(BG);
        ll.setPadding(dp(22), dp(44), dp(22), dp(30));

        TextView t = new TextView(this);
        t.setText("nApps");
        t.setTextColor(INK);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        t.setGravity(Gravity.CENTER);
        ll.addView(t, new LinearLayout.LayoutParams(MATCH, WRAP));

        TextView sub = new TextView(this);
        // NWP-20260825-20 (Chester): the old line promised "it comes back on any nowhere phone"
        // unconditionally. Since the Configuration screen made that a per-source default -- nApps starts at
        // Auto but every bucket is settable, Off included -- the screen was stating an outcome it does not
        // control. Point at the control instead of guessing the answer.
        sub.setText("add an app — Your apps decides whether it comes back");
        sub.setTextColor(MUTED);
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        sub.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(MATCH, WRAP);
        slp.topMargin = dp(5); slp.bottomMargin = dp(2);
        ll.addView(sub, slp);

        headroom = new TextView(this);
        headroom.setTextColor(MUTED);
        headroom.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        headroom.setGravity(Gravity.CENTER);
        ll.addView(headroom, new LinearLayout.LayoutParams(MATCH, WRAP));

        search = new EditText(this);
        search.setHint("Search");
        search.setSingleLine(true);
        search.setTextColor(INK);
        search.setHintTextColor(MUTED);
        search.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        LinearLayout.LayoutParams qlp = new LinearLayout.LayoutParams(MATCH, WRAP);
        qlp.topMargin = dp(8); qlp.bottomMargin = dp(4);
        ll.addView(search, qlp);
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b2, int c) {}
            @Override public void onTextChanged(CharSequence s, int a, int b2, int c) {}
            @Override public void afterTextChanged(Editable e) { reload(e.toString().trim()); }
        });

        status = new TextView(this);
        status.setTextColor(MUTED);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        status.setPadding(0, dp(10), 0, 0);
        status.setText("Loading apps…");
        ll.addView(status, new LinearLayout.LayoutParams(MATCH, WRAP));

        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        ll.addView(list, new LinearLayout.LayoutParams(MATCH, WRAP));

        ScrollView sc = new ScrollView(this);
        sc.setBackgroundColor(BG);
        sc.addView(ll);
        return sc;
    }

    /** NWP-20261103-14 (Q079): ask the chooser to freshen the signed index once per open, so search and its F-Droid
     *  links do not stay on the image's copy. The chooser decides whether data may be spent (the profile's "Download
     *  over mobile data" switch); the reply is ignored, nothing reloads and nothing is shown. An older chooser without
     *  the method throws or answers null -- caught, and the screen is unchanged. Off the main thread: the call blocks
     *  on the daemon for up to 90 s. */
    private void refreshIndexOnce() {
        if (indexAsked) return;
        final INowhereStore s = store;
        if (s == null) return;
        indexAsked = true;
        new Thread(() -> {
            try { s.refreshIndex(); } catch (Throwable ignore) {}
        }, "napps-index").start();
    }

    private void loadHeadroom() {
        new Thread(() -> {
            String line = "";
            try { line = store.getStorageLine(); } catch (Throwable ignore) {}
            final String out = line == null ? "" : line.trim();
            runOnUiThread(() -> {
                if (out.isEmpty()) headroom.setVisibility(View.GONE);
                else { headroom.setVisibility(View.VISIBLE); headroom.setText(out); }
            });
        }, "napps-headroom").start();
    }

    /** Empty query -> the curated catalog; >=2 chars -> the full signed index via the daemon's SEARCH-APPS. */
    private void reload(final String query) {
        pendingQuery = query;
        if (!bound || store == null) return;
        setStatus(query.isEmpty() ? "Loading apps…" : "Searching…");
        new Thread(() -> {
            String json = "";
            try {
                if (query.length() >= 2) {
                    json = store.searchApps(query);
                } else {
                    store.refreshCatalog();  // no-op when unconfigured; a stale catalog still renders
                    json = store.getCatalog();
                }
            } catch (Throwable t) {
                json = "";
            }
            final String body = json;
            runOnUiThread(() -> {
                if (!query.equals(pendingQuery)) return; // a newer keystroke superseded this result
                if (body == null || body.isEmpty()) {
                    setStatus("Couldn't load the app catalog. Check your connection and try again.");
                    list.removeAllViews();
                    return;
                }
                try {
                    org.json.JSONObject o = new org.json.JSONObject(body);
                    org.json.JSONArray entries = o.optJSONArray("apps");
                    if (entries == null) entries = o.optJSONArray("entries");
                    if (entries == null) entries = new org.json.JSONArray();
                    setStatus(query.length() >= 2 ? searchNote(o.optBoolean("truncated", false), o.optLong("generated", 0)) : "");
                    renderCatalog(entries, query.toLowerCase());
                } catch (Throwable t) {
                    setStatus("Couldn't read the app catalog.");
                    list.removeAllViews();
                }
            });
        }, "napps-catalog").start();
    }

    // BEGIN store-compat (lifted verbatim by core/napps/test-store-compat.sh)
    /** Why this phone cannot run an entry, or null. minSdk 0 / empty nativecode = the entry names no constraint. */
    static String incompatReason(int minSdk, String[] nativecode, int sdkInt, String[] supportedAbis) {
        if (minSdk > sdkInt) return "Needs a newer Android";
        if (nativecode != null && nativecode.length > 0) {
            for (String n : nativecode) {
                if (supportedAbis == null) break;
                for (String a : supportedAbis) if (a != null && a.equals(n)) return null;
            }
            return "Not built for this phone";
        }
        return null;
    }

    /** The lines a SEARCH reply earns above the list: the 50-cap notice, then the index date (`generated` is unix seconds). */
    static String searchNote(boolean truncated, long generatedSecs) {
        StringBuilder sb = new StringBuilder();
        if (truncated) sb.append("Showing the top 50 matches. Refine your search to see more.");
        if (generatedSecs > 0) {
            java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US);
            f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
            if (sb.length() > 0) sb.append('\n');
            sb.append("Catalog from ").append(f.format(new java.util.Date(generatedSecs * 1000L)));
        }
        return sb.toString();
    }
    // END store-compat

    private void setStatus(String s) {
        status.setText(s);
        status.setVisibility(s == null || s.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private void renderCatalog(org.json.JSONArray entries, String q) {
        list.removeAllViews();
        String lastCat = null;
        int shown = 0;
        for (int i = 0; i < entries.length(); i++) {
            org.json.JSONObject e = entries.optJSONObject(i);
            if (e == null) continue;
            final String pkg = e.optString("pkg", "");
            if (pkg.isEmpty()) continue;
            String label = e.optString("label", pkg);
            String cat = e.optString("category", "Apps");
            String desc = e.optString("description", "");
            String source = e.optString("source", "");
            String iconRef = e.optString("iconRef", "");
            long size = e.optLong("sizeBytes", 0);
            long vc = e.optLong("versionCode", 0);
            String cert = e.optString("signingCert", "");
            if (!q.isEmpty() && !label.toLowerCase().contains(q) && !pkg.toLowerCase().contains(q)
                    && !cat.toLowerCase().contains(q)) continue;
            if (!cat.equals(lastCat)) {
                lastCat = cat;
                TextView ch = new TextView(this);
                ch.setText(cat);
                ch.setTextColor(MUTED);
                ch.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
                LinearLayout.LayoutParams chp = new LinearLayout.LayoutParams(MATCH, WRAP);
                chp.topMargin = dp(14); chp.bottomMargin = dp(2);
                list.addView(ch, chp);
            }
            // A full-catalog SEARCH result carries iconRef == pkg (the daemon's marker); curated apps keep a
            // data:/https iconRef. Mark those "not curated" and surface F-Droid's anti-feature flags, so the
            // user chooses informed rather than assuming everything here was vetted.
            StringBuilder notice = new StringBuilder();
            if (!iconRef.isEmpty() && iconRef.equals(pkg)) notice.append("Not curated by Nowhere");
            org.json.JSONArray af = e.optJSONArray("antiFeatures");
            if (af != null && af.length() > 0) {
                if (notice.length() > 0) notice.append(" · ");
                notice.append("⚠ ");
                for (int k = 0; k < af.length() && k < 4; k++) {
                    if (k > 0) notice.append(", ");
                    notice.append(af.optString(k, ""));
                }
            }
            String[] nc = null;
            org.json.JSONArray ncj = e.optJSONArray("nativecode");
            if (ncj != null) {
                nc = new String[ncj.length()];
                for (int k = 0; k < nc.length; k++) nc[k] = ncj.optString(k, "");
            }
            String incompat = incompatReason(e.optInt("minSdk", 0), nc, android.os.Build.VERSION.SDK_INT,
                    android.os.Build.SUPPORTED_ABIS);
            if (incompat != null) {
                if (notice.length() > 0) notice.append(" · ");
                notice.append(incompat);
            }
            list.addView(catalogRow(pkg, label, desc, size, source, iconRef, vc, cert, notice.toString(),
                    incompat != null));
            shown++;
        }
        if (shown == 0) {
            TextView none = new TextView(this);
            none.setText("No matches.");
            none.setTextColor(MUTED);
            none.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            none.setPadding(dp(4), dp(16), dp(4), dp(4));
            list.addView(none);
        }
    }

    private LinearLayout catalogRow(final String pkg, final String label, String desc, long size,
                                    String source, String iconRef, final long catalogVc,
                                    final String catalogCert, String notice, boolean incompatible) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(4), dp(12), dp(4), dp(6));

        ImageView icon = new ImageView(this);
        boolean installed = isInstalled(pkg);
        if (installed) {
            try { icon.setImageDrawable(getPackageManager().getApplicationIcon(pkg)); } catch (Throwable ignore) {}
        } else if (iconRef != null && !iconRef.isEmpty()) {
            loadCatalogIcon(icon, iconRef);
        }
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(dp(38), dp(38));
        ilp.rightMargin = dp(12);
        row.addView(icon, ilp);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        TextView lab = new TextView(this);
        lab.setText(label);
        lab.setTextColor(INK);
        lab.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        col.addView(lab);
        if (desc != null && !desc.isEmpty()) col.addView(sub(desc, false));
        StringBuilder meta = new StringBuilder();
        if (size > 0) meta.append("~").append(humanBytes(size));
        if (source != null && !source.isEmpty()) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append(source);
        }
        if (meta.length() > 0) col.addView(sub(meta.toString(), true));
        // h49 #1: "In your apps · not on this phone yet" under Download, and under Update of an archived placeholder.
        final TextView grey = sub("", true);
        grey.setVisibility(View.GONE);
        col.addView(grey);
        if (notice != null && !notice.isEmpty()) {
            TextView nt = new TextView(this);
            nt.setText(notice);
            nt.setTextColor(WARN);
            nt.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            nt.setMaxLines(3);
            col.addView(nt);
        }
        row.addView(col, new LinearLayout.LayoutParams(0, WRAP, 1f));

        final TextView action = new TextView(this);
        action.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        action.setPadding(dp(16), dp(7), dp(16), dp(7));
        action.setMinWidth(dp(84));
        action.setGravity(Gravity.CENTER);
        NappsAction.State st = paintAction(action, grey, pkg, catalogVc, catalogCert);
        if (incompatible && st == NappsAction.State.GET) {
            // A label, not a filter: the row stays so the user learns why, but Get would only end in a generic installer error.
            // Only for Get: Download takes the session's own sealed copy, which this phone already ran.
            action.setText("Not compatible with this device");
            action.setTextColor(MUTED);
            action.setMaxWidth(dp(120));
            action.setEnabled(false);
        } else {
            action.setOnClickListener(v -> onGet(pkg, label, action, grey, catalogVc, catalogCert));
        }
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(WRAP, WRAP);
        alp.leftMargin = dp(8);
        row.addView(action, alp);
        return row;
    }

    private TextView sub(String text, boolean tight) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextColor(MUTED);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, tight ? 12 : 13);
        if (!tight) t.setMaxLines(2);
        return t;
    }

    private boolean isInstalled(String pkg) {
        try { getPackageManager().getPackageInfo(pkg, 0); return true; } catch (Throwable t) { return false; }
    }

    private long installedVc(String pkg) {
        try { return getPackageManager().getPackageInfo(pkg, 0).getLongVersionCode(); } catch (Throwable t) { return -1; }
    }

    /** The package as an archived placeholder or an installed app, with its signers: the read that also matches an
     *  archived package. MATCH_ARCHIVED_PACKAGES is a LONG, so it only reaches PM through PackageInfoFlags.of() -- the
     *  int overload would drop it and an archived app would read as absent. null on any failure. */
    private android.content.pm.PackageInfo archivedInfo(String pkg) {
        try {
            return getPackageManager().getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(
                    android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES
                            | android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES));
        } catch (Throwable t) {
            return null;
        }
    }

    /** The row's state from PackageManager and the catalog entry (NWP-20261119-19). archivedOut[0] is set when the
     *  package is an archived placeholder: its code is not on this phone, but the session holds it. */
    private NappsAction.State stateFor(String pkg, long catalogVc, String catalogCert, boolean[] archivedOut) {
        long codeVc = installedVc(pkg);
        boolean hasCode = codeVc >= 0;
        android.content.pm.PackageInfo pi = archivedInfo(pkg);
        boolean archived = !hasCode && pi != null;
        long haveVc = hasCode ? codeVc : (pi != null ? pi.getLongVersionCode() : -1);
        java.util.List<String> certs = new java.util.ArrayList<>();
        try {
            android.content.pm.Signature[] sigs = pi != null && pi.signingInfo != null
                    ? pi.signingInfo.getApkContentsSigners() : null;
            if (sigs != null) for (android.content.pm.Signature g : sigs) if (g != null) certs.add(NappsAction.certHex(g.toByteArray()));
        } catch (Throwable t) {
            certs.clear(); // no known signer -> not the same publisher -> Download, the sealed copy
        }
        if (archivedOut != null) archivedOut[0] = archived;
        return NappsAction.state(hasCode, archived, haveVc, catalogVc, NappsAction.sameSigner(catalogCert, certs));
    }

    private NappsAction.State paintAction(TextView action, TextView grey, String pkg, long catalogVc, String catalogCert) {
        boolean[] archived = new boolean[1];
        NappsAction.State st = stateFor(pkg, catalogVc, catalogCert, archived);
        action.setText(NappsAction.label(st));
        action.setTextColor(st == NappsAction.State.ADDED ? MUTED : ACCENT);
        String g = NappsAction.greyLine(st, archived[0]);
        grey.setText(g == null ? "" : g);
        grey.setVisibility(g == null ? View.GONE : View.VISIBLE);
        return st;
    }

    /** The install runs in the CHOOSER (it owns the privileged permission); we only ask and report. */
    private void onGet(final String pkg, final String label, final TextView action, final TextView grey,
                       final long catalogVc, final String catalogCert) {
        if (!bound || store == null) return;
        // By state, not by the button's text: the state is re-read at the tap, so a stale label cannot misroute it.
        NappsAction.State st = stateFor(pkg, catalogVc, catalogCert, null);
        if (st == NappsAction.State.ADDED) return;
        if (st == NappsAction.State.DOWNLOAD) {
            // h49 #1, Q051: the session's own sealed copy, never the catalog build.
            downloadOwn(pkg, label, action, grey, catalogVc, catalogCert);
            return;
        }
        action.setText("…");
        action.setTextColor(MUTED);
        action.setEnabled(false); // review: an in-flight row must not be re-tappable (the old path disabled it too)
        // NWP-20260825-20 (Chester: "just the '...' is not very meaningful and there is no real notification
        // that an app is getting installed"). getApp() below is ONE blocking call covering download + hash +
        // signer check + staging + install -- minutes for a large app -- and until it returned, the row's "…"
        // was the entire story. The chooser also raises a shade notification for the same span, so the answer
        // survives leaving this screen.
        setStatus("Adding " + label + " — downloading…");
        new Thread(() -> {
            String reply;
            // NWP-20260921-12: pass the catalog label so the chooser's install notification can name the app.
            // The notice is posted BEFORE the download, when PackageManager cannot know a new package yet.
            try { reply = store.getApp(pkg, label); } catch (Throwable t) { reply = "ERR " + t.getClass().getSimpleName(); }
            final String r = reply == null ? "" : reply.trim();
            runOnUiThread(() -> {
                action.setEnabled(true);
                if (r.startsWith("OK-SESSION-ONLY")) {
                    // #136, honestly: installed, but the keep was refused because the plan is full.
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " installed for this session only — you're over your storage plan, so it won't come back.");
                } else if (r.startsWith("OK-UNSAVED")) {
                    // NWP-20261105-03: installed, but the keep line could not be written -- not "added".
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " installed for this session only — it couldn't be added to this profile's apps, so it won't come back after you sign out.");
                } else if (r.startsWith("OK-OFF")) {
                    // NWP-20261129-38: installed, but an Off nApps default wrote no keep line -- not "added". Drafted
                    // words, for Chester to correct (the way of working of #43).
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " installed for this session only — new apps from nApps start Off on this profile, so it won't come back after you sign out. You can keep it in Profile › Preferences › Your apps.");
                } else if (r.startsWith("OK")) {
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " added.");
                } else if ("ERR-BUSY".equals(r)) {
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " is already being added.");
                } else if ("ERR-PENDING".equals(r)) {
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus(label + " is still installing — check again in a moment.");
                } else if ("ERR-NOSIGNER".equals(r)) {
                    // NWP-20261030-05: the store refuses an entry that names no publisher signature.
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus("Couldn't add " + label + " — its store entry names no publisher signature to check it against, so it isn't installed.");
                } else {
                    // Name the cause the daemon gave. #140: a screen that cannot say what failed invents a
                    // reason, and the invented one is usually an accusation aimed at the user.
                    paintAction(action, grey, pkg, catalogVc, catalogCert);
                    setStatus("Couldn't add " + label + (r.isEmpty() ? "." : " — " + r));
                }
            });
        }, "napps-get").start();
    }

    /** Download (NWP-20261119-19, h49 #1, Q051): ask the chooser to materialise the session's own sealed copy. The
     *  chooser starts the same worker an unarchive tap starts, so the group brings its Play dependencies, the progress
     *  notification and the "Getting <app> ready…" screen take over, and the app opens when it is whole. It never asks
     *  for the catalog build. */
    private void downloadOwn(final String pkg, final String label, final TextView action, final TextView grey,
                             final long catalogVc, final String catalogCert) {
        action.setText("…");
        action.setTextColor(MUTED);
        action.setEnabled(false);
        setStatus(NappsAction.downloadingStatus(label));
        new Thread(() -> {
            String reply;
            try { reply = store.materializeOwn(pkg); } catch (Throwable t) { reply = "ERR " + t.getClass().getSimpleName(); }
            final String r = reply == null ? "" : reply.trim();
            runOnUiThread(() -> {
                action.setEnabled(true);
                paintAction(action, grey, pkg, catalogVc, catalogCert);
                if ("OK".equals(r)) return; // the status line stays; the chooser shows the progress from here
                if ("ERR-NOTARCHIVED".equals(r)) {
                    // The package changed state since the row was painted (the Auto sweep landed it, say); the
                    // repaint above shows what is true now.
                    setStatus("");
                    return;
                }
                // #140: name the cause the chooser gave.
                setStatus("Couldn't download your copy of " + label + (r.isEmpty() ? "." : " — " + r));
            });
        }, "napps-download").start();
    }

    private void loadCatalogIcon(final ImageView iv, final String url) {
        Bitmap cached = iconCache.get(url);
        if (cached != null) { iv.setImageBitmap(cached); return; }
        if (url.startsWith("data:")) { // baked into the signed catalog -> decode locally, nothing leaves the phone
            Bitmap bmp = decodeDataUri(url);
            if (bmp != null) { iconCache.put(url, bmp); iv.setImageBitmap(bmp); }
            return;
        }
        iv.setTag(url); // rows are rebuilt on every render -> only apply if this view still wants this url
        new Thread(() -> {
            Bitmap bmp = null;
            try {
                byte[] raw = store.fetchIcon(url);
                if (raw != null && raw.length > 0) bmp = BitmapFactory.decodeByteArray(raw, 0, raw.length);
            } catch (Throwable ignore) {}
            if (bmp == null) return;
            final Bitmap out = bmp;
            iconCache.put(url, out);
            runOnUiThread(() -> {
                if (!isFinishing() && !isDestroyed() && url.equals(iv.getTag())) iv.setImageBitmap(out);
            });
        }, "napps-icon").start();
    }

    private static Bitmap decodeDataUri(String url) {
        try {
            int comma = url.indexOf(',');
            if (comma < 0 || !url.substring(0, comma).contains("base64")) return null;
            byte[] bytes = android.util.Base64.decode(url.substring(comma + 1), android.util.Base64.DEFAULT);
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (Throwable t) {
            return null;
        }
    }

    private static String humanBytes(long b) {
        if (b <= 0) return "0 B";
        String[] u = {"B", "KB", "MB", "GB"};
        int i = 0;
        double d = b;
        while (d >= 1024 && i < u.length - 1) { d /= 1024; i++; }
        return (d >= 10 || i == 0 ? String.valueOf(Math.round(d)) : String.format("%.1f", d)) + " " + u[i];
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
