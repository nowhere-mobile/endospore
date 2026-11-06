package com.nowhere.chooser;

import android.app.Service;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.IBinder;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Serves the storefront's data to the separate nApps app (DIA-20260818-08, #747).
 *
 * THE POINT OF THE SEAM. nApps is its own package so it shows up in Settings > Apps as its own app. But the
 * login daemon pins the FIRST peer's appId on the socket and rejects every other one (SO_PEERCRED
 * trust-on-first-use, main.go:4136-4146; its own comment: "a roamed app would be a different package").
 * That is defence-in-depth from audit #2 (DIA-20260618-08). Splitting the UI out could have been done by
 * teaching the daemon to trust two packages -- and that would have paid for a Settings row with a weaker
 * security boundary. So instead the chooser stays the ONLY package that ever opens the socket, and nApps
 * asks it. Nothing about the daemon's identity model changes.
 *
 * The install stays here too, for the same reason: FETCH-APP stages verified bytes and the install needs the
 * chooser's privileged package-install permission. A UI package should not hold that authority.
 *
 * The socket plumbing below is deliberately a small private copy rather than a refactor of ProfileActivity's
 * helpers. ProfileActivity is one 7k-line class whose members reach each other freely; carving shared statics
 * out of it to serve this file would touch far more than this change needs, on a screen the fleet depends on.
 * The protocol is four lines of framing, and duplicating those four is the cheaper risk.
 *
 * Every method here blocks on a single-threaded daemon. Binder already dispatches on a pool thread, so this
 * is the right side of the boundary for that -- but callers in nApps must still stay off ITS main thread.
 */
public class StoreService extends Service {

    private static final String TAG = "NowhereStore";
    private static final String SOCKET = "nowhere_login";

    /** Reply cap for the catalog/search bodies. Matches ProfileActivity's original 30s for the same verbs. */
    private static final int READ_CAP_MS = 30000;
    /** REFRESH-CATALOG pulls over the network via the daemon; it gets the same 50s the chooser gave it. */
    private static final int REFRESH_CAP_MS = 50000;
    /** FETCH-APP downloads and verifies a whole apk set -- minutes, not seconds. */
    private static final int FETCH_APP_CAP_MS = 600000;
    /** REFRESH-INDEX: the daemon's own deadline for the verb (main.go, 90 s for a few-MB signed index). */
    private static final int REFRESH_INDEX_CAP_MS = 90000;

    @Override
    public IBinder onBind(Intent intent) {
        return mBinder;
    }

    private final INowhereStore.Stub mBinder = new INowhereStore.Stub() {
        @Override
        public String getStorageLine() {
            String s = line("GET-ENTITLEMENT\n", READ_CAP_MS);
            if (s == null) return "";
            // NWP-20260825-20: format HERE. This used to return the wire line and nApps rendered it verbatim,
            // so the storefront header read "OK used=1181116 free=1073741824 entitled=0 covered=..." to the
            // user. nApps holds no authority and should not be parsing economics; the billing vocabulary lives
            // on this side. withManage=false: nApps has no route to the Storage screen, so offering "Manage ›"
            // there would be a dead affordance.
            CharSequence f = ProfileActivity.formatHeadroom(s.trim(), false);
            return f == null ? "" : f.toString();
        }

        @Override
        public void refreshCatalog() {
            line("REFRESH-CATALOG\n", REFRESH_CAP_MS); // OK | NONE | ERR -- best effort, a stale catalog still serves
        }

        @Override
        public String getCatalog() {
            byte[] b = lenReply("GET-CATALOG\n", READ_CAP_MS);
            return b == null ? "" : new String(b, java.nio.charset.StandardCharsets.UTF_8);
        }

        @Override
        public String searchApps(String query) {
            if (query == null) return "";
            byte[] b = lenReply("SEARCH-APPS\n" + query + "\n", READ_CAP_MS);
            return b == null ? "" : new String(b, java.nio.charset.StandardCharsets.UTF_8);
        }

        @Override
        public byte[] fetchIcon(String url) {
            if (url == null || url.isEmpty() || url.startsWith("data:")) return null; // data: is decoded caller-side
            return lenReply("FETCH-ICON\n" + url + "\n", READ_CAP_MS);
        }

        @Override
        public String getApp(String pkg, String label) {
            if (pkg == null || pkg.isEmpty()) return "ERR no package";
            // Review (P1 belt): the install verb acts with the chooser's privileged permission -- assert the
            // binder caller really is the storefront, not merely a holder of the signature permission.
            if (!callerIsStorefront()) return "ERR-CALLER";
            // Review: a double-tap (or a second client) must short-circuit, not race two PackageInstaller
            // sessions whose finally-cleanups delete each other's staged bytes.
            if (!StoreInstaller.IN_FLIGHT.add(pkg)) return "ERR-BUSY";
            postInstallNotice(pkg, label);
            try {
                // NWP-20261122-14: the `progress` opt-in streams PROGRESS lines ahead of the verdict, and each one
                // moves the notification's bar. The verdict is the first other line, read as before.
                String s = fetchVerdict("FETCH-APP\n" + pkg + " 0 progress\n", FETCH_APP_CAP_MS,
                        (got, total) -> postInstallNotice(pkg, label, got, total));
                // Report the daemon's own verdict rather than a generic failure: #140's lesson is that a
                // screen which cannot name the cause invents one, usually an accusation aimed at the user.
                if (s == null) return "ERR no reply";
                if (!s.startsWith("OK")) return s;
                // NWP-20260819-03: the half the #747 split dropped -- "NotePad added." with the APK parked
                // in .appcode and "Get" truthfully repainting from the uninstalled reality (lynx,
                // 2026-08-19). Install synchronously on this binder thread, keep via the decided defaults,
                // and only then report OK -- so the storefront renders "Added" from fact.
                //
                // The SIGNER PIN is the daemon's, never the caller's (review P1: a hostile caller stripped
                // the gate with ""). FETCH-APP's OK is "OK <pkg> <signerHex|->": the entry the daemon
                // resolved from the SIGNED catalog/index. "-" == the catalog genuinely omits the cert.
                String signer = StoreSignerPin.fromFetchReply(s, pkg);
                if (signer == null) Log.w(TAG, "getApp FETCH-APP " + pkg + ": reply is not OK <pkg> <signer|-> -- refusing");
                String verdict = StoreInstaller.installStaged(StoreService.this, pkg, signer);
                if (StoreInstaller.PENDING.equals(verdict)) return "ERR-PENDING";
                if (StoreInstaller.NOSIGNER.equals(verdict)) return "ERR-NOSIGNER";
                if (!StoreInstaller.OK.equals(verdict)) return "ERR-INSTALL";
                // NWP-20260821-15: an app installed AFTER this session's presence snapshot must join the receipt,
                // or a store install the user then changes their mind about and uninstalls keeps its keep line and
                // comes back on the next roam -- the reported bug through a narrower window. Gated on the OK
                // verdict specifically: PENDING is "outcome unknown, not failure" (see installStaged) and returns
                // above, so an unconfirmed install can never be recorded as observed-present.
                StoreInstaller.noteAppSeen(StoreService.this, pkg);
                // #136 over-plan gate, #130 AUTO store default -- an over-plan Get installs for THIS
                // SESSION ONLY, and the storefront is told so it can say so instead of lying "Added".
                boolean overPlan = StoreInstaller.overPlanLine(line("GET-ENTITLEMENT\n", READ_CAP_MS));
                boolean kept = StoreInstaller.keepAuto(StoreService.this, pkg, overPlan);
                StoreInstaller.dropManifestLine(StoreService.this, pkg);
                return getAppReply(kept, overPlan, pkg);
            } finally {
                StoreInstaller.IN_FLIGHT.remove(pkg);
                cancelInstallNotice(pkg);
            }
        }

        // NWP-20261103-14 (Q079): freshen the signed index once per storefront open. Metered data is spent only
        // behind the profile's "Download over mobile data" switch; a repeat refresh is a conditional GET
        // (NWP-20261102-11), so an unchanged index costs almost nothing.
        @Override
        public String refreshIndex() {
            if (!callerIsStorefront()) return "ERR-CALLER";
            boolean metered = activeNetworkMetered();
            String allow = line("GET-PREFETCH-METERED\n", READ_CAP_MS);
            if (!indexRefreshAllowed(metered, allow)) return "SKIPPED"; // metered and the switch is off
            String s = line("REFRESH-INDEX\n", REFRESH_INDEX_CAP_MS); // OK | NONE | ERR
            return s == null ? "ERR no reply" : s;
        }

        // NWP-20261119-19 (h49 #1, Q051): nApps's "Download" for an On-demand app the session already holds. The tap
        // takes the sealed copy through the same worker an unarchive tap starts, so the group brings its Play
        // dependencies and the progress queue applies. Only PM reads and one keep-set read run here; the download
        // runs in UnarchiveService's worker.
        @Override
        public String materializeOwn(String pkg) {
            if (!callerIsStorefront()) return "ERR-CALLER";
            if (pkg == null || pkg.isEmpty()
                    || !mayMaterializeOwn(UnarchiveService.hasInstalledCode(StoreService.this, pkg), archivedHere(pkg),
                            ProfileActivity.deferredKeepSet(StoreService.this).contains(pkg)))
                return "ERR-NOTARCHIVED";
            try {
                // As UnarchiveReceiver starts it, without an unarchive id: no system card waits on a status report.
                startForegroundService(new Intent(StoreService.this, UnarchiveService.class)
                        .putExtra(UnarchiveService.EXTRA_PKG, pkg));
                return "OK";
            } catch (Throwable t) {
                Log.w(TAG, "materializeOwn " + pkg + ": UnarchiveService did not start", t);
                return "ERR";
            }
        }
    };

    /** NWP-20260825-20. Chester: "there is no real notification that an app is getting installed".
     *
     *  getApp() is a SINGLE blocking round trip covering download, hash check, signer pin, staging and
     *  install -- minutes for a large app. The only feedback was the storefront row's "…", which is gone the
     *  moment the user leaves the screen, and nothing at all in the shade. Every other long operation here
     *  already raises one (backup, storage, offline), so this is the missing member of that set rather than a
     *  new idea.
     *
     *  It is posted from the CHOOSER, not from nApps: this process is where the install actually happens, so
     *  the notification's lifetime is the operation's lifetime by construction. nApps could not do it honestly
     *  -- it only knows "I asked" and "it answered". Ongoing progress: since NWP-20261122-14 FETCH-APP streams
     *  PROGRESS byte counts, so the bar is a real one with "<got> of <total>" (InstallProgress). It stays
     *  indeterminate until the first count, and for an entry that states no size. IMPORTANCE_LOW: informative,
     *  not urgent. Failure to post must never cost the user their install, hence the blanket catch. */
    private static final String NOTIF_INSTALL_CHANNEL = "nowhere_app_install";

    private void postInstallNotice(String pkg, String label) {
        postInstallNotice(pkg, label, 0, 0);
    }

    /** The same notice at got of total bytes; total 0 keeps the indeterminate bar and today's text. Same id, so
     *  each PROGRESS line updates the one notice, and it alerts once only. */
    private void postInstallNotice(String pkg, String label, long got, long total) {
        try {
            android.app.NotificationManager nm = getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            android.app.NotificationChannel ch = new android.app.NotificationChannel(
                    NOTIF_INSTALL_CHANNEL, "App installs", android.app.NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("Shows while an app you asked for is being downloaded and installed");
            nm.createNotificationChannel(ch);
            String text = InstallProgress.text(got, total);
            int[] bar = InstallProgress.bar(got, total);
            android.app.Notification n = new android.app.Notification.Builder(this, NOTIF_INSTALL_CHANNEL)
                    .setSmallIcon(R.drawable.ic_nowhere_notif)
                    .setContentTitle("Adding " + installTitleFor(pkg, label))
                    .setContentText(text == null ? "Downloading and installing…" : text)
                    .setProgress(bar == null ? 0 : bar[0], bar == null ? 0 : bar[1], bar == null)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setShowWhen(false)
                    .build();
            nm.notify(NOTIF_INSTALL_CHANNEL, pkg.hashCode(), n);
        } catch (Throwable t) {
            Log.w(TAG, "postInstallNotice", t);
        }
    }

    private void cancelInstallNotice(String pkg) {
        try {
            android.app.NotificationManager nm = getSystemService(android.app.NotificationManager.class);
            if (nm != null) nm.cancel(NOTIF_INSTALL_CHANNEL, pkg.hashCode());
        } catch (Throwable t) {
            Log.w(TAG, "cancelInstallNotice", t);
        }
    }

    /** What to call the app in the shade while it installs, best source first (NWP-20260921-12).
     *
     *  ⚠⚠ THE ORDER IS THE WHOLE FIX. This notice is posted BEFORE the download, so for a NEW package
     *  PackageManager does not know it yet and labelFor() always fell through to `return pkg` -- which is
     *  why every fresh install read "Adding com.example.notepad". The catalog label is the only source
     *  that exists at this instant, and nApps already had it; it just never crossed the AIDL.
     *
     *  ⚠ THE LABEL IS CALLER-SUPPLIED AND DISPLAY-ONLY. It is sanitised here rather than trusted: a
     *  notification title is a single line, so newlines and runs of whitespace are collapsed and the
     *  result is capped. It reaches nothing but this string -- never the signer pin, the keep decision or
     *  any identity check (see the AIDL's note, which makes the same point about the pin).
     *
     *  Falls back to PackageManager (correct for an UPDATE, where the installed label is authoritative and
     *  fresher than a catalog entry) and finally to the package id. Never blank. */
    private String installTitleFor(String pkg, String label) {
        if (label != null) {
            String s = label.replaceAll("\\s+", " ").trim();
            if (!s.isEmpty()) return s.length() > 60 ? s.substring(0, 60).trim() + "…" : s;
        }
        return labelFor(pkg);
    }

    /** The app's own label if PM already knows the package (an update), else the package name -- never a
     *  blank. Used as installTitleFor()'s fallback, and correct on its own for anything already installed. */
    private String labelFor(String pkg) {
        try {
            android.content.pm.PackageManager pm = getPackageManager();
            return pm.getApplicationInfo(pkg, 0).loadLabel(pm).toString();
        } catch (Throwable ignore) {
            return pkg;
        }
    }

    /** Review (P1 belt): the signature permission gates WHO may bind, but the install verb acts with the
     *  chooser's privileged permission -- assert the binder caller really is the storefront package (or
     *  this package itself), not merely any platform-signed app that declared the permission. */
    private boolean callerIsStorefront() {
        try {
            String[] pkgs = getPackageManager().getPackagesForUid(android.os.Binder.getCallingUid());
            if (pkgs == null) return false;
            for (String p : pkgs) {
                if ("com.nowhere.napps".equals(p) || getPackageName().equals(p)) return true;
            }
            Log.w(TAG, "store call refused: caller uid " + android.os.Binder.getCallingUid() + " is not the storefront");
            return false;
        } catch (Throwable t) {
            return false; // an unverifiable caller does not get an install
        }
    }

    /** The package is an archived placeholder in this (the caller's) user: the archived read resolves it.
     *  MATCH_ARCHIVED_PACKAGES is a LONG, so it only reaches PM through PackageInfoFlags.of(). Any failure is false: no
     *  install starts. */
    private boolean archivedHere(String pkg) {
        try {
            return getPackageManager().getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(
                    android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES)) != null;
        } catch (Throwable t) {
            return false;
        }
    }

    /** The active network is metered, or cannot be read -- FAIL-CLOSED, unlike ChooserActivity.hasInternet: a wrong
     *  guess here spends the user's data. No active network counts as metered. */
    private boolean activeNetworkMetered() {
        try {
            android.net.ConnectivityManager cm = getSystemService(android.net.ConnectivityManager.class);
            if (cm == null) return true;
            android.net.Network nw = cm.getActiveNetwork();
            if (nw == null) return true;
            android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(nw);
            return nc == null || !nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        } catch (Throwable t) {
            return true;
        }
    }

    // BEGIN index-refresh-gate (lifted verbatim by core/chooser/tests/index-refresh-gate/run.sh)
    /** May REFRESH-INDEX spend data now? Unmetered: yes. Metered: only on a GET-PREFETCH-METERED reply of exactly "1"
     *  -- null (no daemon), "", "0" or anything else is no. */
    static boolean indexRefreshAllowed(boolean metered, String prefetchMeteredReply) {
        if (!metered) return true;
        return prefetchMeteredReply != null && "1".equals(prefetchMeteredReply.trim());
    }
    // END index-refresh-gate

    // BEGIN materialize-own (lifted verbatim by core/vendor-common/bin/test-napps-action-java.sh)
    /** May materializeOwn start the sealed materialise? Only for an archived placeholder (no code, the archived record
     *  resolves) that the keep-set holds as deferred (On-demand or Auto: only those have a sealed copy). */
    static boolean mayMaterializeOwn(boolean hasCode, boolean archivedHere, boolean inKeepSet) {
        return !hasCode && archivedHere && inKeepSet;
    }
    // END materialize-own

    /** NWP-20261105-03: getApp's success reply, from what keepAuto answered and whether the over-plan gate refused.
     *  Kept: "OK". Not kept because of the gate: "OK-SESSION-ONLY". Not kept with the gate open: the keep line could
     *  not be written, "OK-UNSAVED" -- nApps must not say "added" for an app that will be gone at the next sign-in. */
    static String getAppReply(boolean kept, boolean overPlan, String pkg) {
        if (kept) return "OK " + pkg;
        return (overPlan ? "OK-SESSION-ONLY " : "OK-UNSAVED ") + pkg;
    }

    /** One command, first reply line. null on any failure. */
    private static String line(String cmd, int capMs) {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(capMs);
            OutputStream os = s.getOutputStream();
            os.write(cmd.getBytes("UTF-8"));
            os.flush();
            return readLine(s.getInputStream());
        } catch (Throwable t) {
            Log.w(TAG, "line " + firstToken(cmd), t);
            return null;
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** NWP-20261122-14: the PROGRESS counts of a FETCH-APP that opted in. */
    private interface ProgressSink { void on(long got, long total); }

    /** One FETCH-APP with the `progress` opt-in: hands each well-formed PROGRESS line to sink (a malformed one is
     *  skipped) and returns the first other line, the verdict. null on EOF, timeout or any failure, as line().
     *  capMs bounds the WHOLE exchange: each read waits only for what is left of it, so a stream of PROGRESS lines
     *  can never extend the wait. A sink failure never costs the install. */
    private static String fetchVerdict(String cmd, int capMs, ProgressSink sink) {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            long deadline = System.currentTimeMillis() + capMs;
            OutputStream os = s.getOutputStream();
            os.write(cmd.getBytes("UTF-8"));
            os.flush();
            InputStream in = s.getInputStream();
            while (true) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) throw new java.io.IOException("FETCH-APP cap reached");
                s.setSoTimeout((int) Math.min(left, Integer.MAX_VALUE));
                String l = readLine(in);
                if (l == null || !InstallProgress.isProgress(l)) return l;
                long[] p = InstallProgress.parse(l);
                if (p == null) continue;
                try {
                    sink.on(p[0], p[1]);
                } catch (Throwable t) {
                    Log.w(TAG, "fetchVerdict progress", t);
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "fetchVerdict " + firstToken(cmd), t);
            return null;
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** One command, a length-prefixed body: "OK <n>\n" then exactly n bytes. null on NONE/ERR/any failure. */
    private static byte[] lenReply(String cmd, int capMs) {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(capMs);
            OutputStream os = s.getOutputStream();
            os.write(cmd.getBytes("UTF-8"));
            os.flush();
            InputStream in = s.getInputStream();
            String head = readLine(in);
            if (head == null || !head.startsWith("OK")) return null; // NONE | ERR | closed
            int sp = head.indexOf(' ');
            if (sp < 0) return null;
            int n;
            try {
                n = Integer.parseInt(head.substring(sp + 1).trim());
            } catch (NumberFormatException nfe) {
                return null;
            }
            if (n <= 0) return null;
            // Read EXACTLY n bytes. A short read is a truncated body, not a small one -- returning it would
            // hand the caller half a catalog to parse, which fails later and further from the cause.
            byte[] out = new byte[n];
            int got = 0;
            while (got < n) {
                int r = in.read(out, got, n - got);
                if (r < 0) return null;
                got += r;
            }
            return out;
        } catch (Throwable t) {
            Log.w(TAG, "lenReply " + firstToken(cmd), t);
            return null;
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** Read one \n-terminated line without buffering past it -- a BufferedReader would swallow body bytes. */
    private static String readLine(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream(64);
        int c;
        while ((c = in.read()) >= 0) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
        }
        if (c < 0 && b.size() == 0) return null;
        return new String(b.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
    }

    private static String firstToken(String cmd) {
        int nl = cmd.indexOf('\n');
        return nl < 0 ? cmd : cmd.substring(0, nl);
    }
}
