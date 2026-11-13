package com.nowhere.chooser;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

import java.io.File;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/** NWP-20261126-02: a beta profile's scheduled diagnostic report (decision 2026-11-02, docs/product-decisions.md,
 *  NWP-20261102-29). One periodic job in the session's own user, hourly, not persisted: the user ends with the session,
 *  and UnarchiveService.sweepAuto calls arm() at every landing. The rules of a run are DiagReports.runJob: it sends
 *  only when the agent answers `DIAG-SUMMARY status` with OFFERED 1 (the beta stack), the opt-in still says on under
 *  the consent lock and DiagReports.due says SEND. It never retries inside a run and never sends because something
 *  failed. A scheduled ticket is not added to the Report an issue ticket table.
 *  No log line holds the tag. */
public class DiagReportJob extends JobService {
    static final int JOB_ID = 0x4E444752; // "NDGR"; no other JobScheduler user in the chooser

    /** The periodic job, unless it is already pending (a repeated arm must not push the period back). Returns the
     *  record's code (NWP-20261202-08): scheduled, pending, nojs, err-result (RESULT_FAILURE, which does not throw) or
     *  DiagReports.throwCode's. */
    static String schedule(Context ctx) {
        try {
            JobScheduler js = ctx.getSystemService(JobScheduler.class);
            if (js == null) return "nojs";
            if (js.getPendingJob(JOB_ID) != null) return "pending";
            int r = js.schedule(new JobInfo.Builder(JOB_ID, new ComponentName(ctx, DiagReportJob.class))
                    .setPeriodic(3600_000L)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPersisted(false)
                    .build());
            return r == JobScheduler.RESULT_SUCCESS ? "scheduled" : "err-result";
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "diag reports: schedule failed (NWP-20261126-02)", t);
            return DiagReports.throwCode(t);
        }
    }

    /** NWP-20261202-08: 1 when the job is pending now, 0 when not, err when JobScheduler could not say. */
    static String pending(Context ctx) {
        try {
            JobScheduler js = ctx.getSystemService(JobScheduler.class);
            if (js == null) return "err";
            return js.getPendingJob(JOB_ID) != null ? "1" : "0";
        } catch (Throwable t) {
            return "err";
        }
    }

    /** NWP-20261202-08: onStartJob / onStopJob's record, only with the opt-in on, so the stop a switchOff's cancel
     *  causes records nothing. It takes RUNS_LOCK only, never LOCK: onStopJob runs on the main thread. */
    static void noteJob(Context ctx, String ev) {
        try {
            if (DiagReports.optedIn(readFile(ctx, DiagReports.OPT_FILE))) DiagReports.record(new AndroidPort(ctx), ev, "ok");
        } catch (Throwable ignore) {
            // a record never stops the job
        }
    }

    static void cancel(Context ctx) {
        try {
            JobScheduler js = ctx.getSystemService(JobScheduler.class);
            if (js != null) js.cancel(JOB_ID);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "diag reports: cancel failed (NWP-20261126-02)", t);
        }
    }

    /** At a session landing: DiagReports.arm under the consent lock. Off the main thread (the sweep's own thread). */
    static void arm(Context ctx) {
        DiagReports.arm(new AndroidPort(ctx));
    }

    /** A profile file's text; "" when absent or unreadable. */
    static String readFile(Context ctx, String name) {
        File f = new File(ctx.getFilesDir(), name);
        if (!f.exists()) return "";
        try { return KeepOrder.readText(f); }
        catch (Throwable t) { return ""; }
    }

    /** Write a profile file whole (temp + rename); false on failure. */
    static boolean writeFile(Context ctx, String name, String text) {
        try {
            StoreInstaller.writeAtomic(new File(ctx.getFilesDir(), name), text);
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "diag reports: " + name + " not written (" + t.getClass().getSimpleName() + ")");
            return false;
        }
    }

    /** The running job's stop flag: onStopJob (a cancel from the switch, a lost network) sets it, and the run checks
     *  it under the consent lock before it sends. */
    private volatile AtomicBoolean stop;

    @Override public boolean onStartJob(final JobParameters params) {
        final Context ctx = getApplicationContext();
        final AtomicBoolean s = new AtomicBoolean(false);
        stop = s;
        Thread t = new Thread(() -> {
            try {
                String r = DiagReports.runJob(new AndroidPort(ctx), s);
                android.util.Log.i("NowhereChooser", "diag reports: run " + r);
            }
            catch (Throwable e) { android.util.Log.w("NowhereChooser", "diag reports: run failed (NWP-20261126-02)", e); }
            finally { jobFinished(params, false); }
        }, "diag-reports");
        t.setDaemon(true);
        noteJob(ctx, "start");
        t.start();
        return true;
    }

    @Override public boolean onStopJob(JobParameters params) {
        AtomicBoolean s = stop;
        if (s != null) s.set(true);
        noteJob(getApplicationContext(), "stop");
        return false; // no reschedule: the next period runs it again
    }

    /** The device's DiagReports.Port: the profile's files, the daemon socket, JobScheduler, ConnectivityManager. */
    static final class AndroidPort implements DiagReports.Port {
        private final Context ctx;
        AndroidPort(Context ctx) { this.ctx = ctx; }
        @Override public String read(String file) { return readFile(ctx, file); }
        @Override public boolean write(String file, String text) { return writeFile(ctx, file, text); }
        @Override public void remove(String file) { new File(ctx.getFilesDir(), file).delete(); }
        @Override public String status() { return statusRequest(); }
        @Override public String on() { return onRequest(); }
        @Override public String off() { return offRequest(); }
        @Override public String report(Map<String, String> extra) { return sendScheduled(ctx, extra); }
        @Override public String schedule() { return DiagReportJob.schedule(ctx); }
        @Override public String pending() { return DiagReportJob.pending(ctx); }
        @Override public void cancel() { DiagReportJob.cancel(ctx); }
        @Override public boolean[] net() { return netState(ctx); }
        @Override public long now() { return System.currentTimeMillis(); }
        @Override public String newTag() { return DiagReports.newTag(new java.security.SecureRandom()); }
    }

    private static String statusRequest() {
        return DaemonSocket.roundTrip("DIAG-SUMMARY\nstatus\n", 15000);
    }

    private static String onRequest() {
        String r = DaemonSocket.roundTrip("DIAG-SUMMARY\non\n", 15000);
        android.util.Log.i("NowhereChooser", "diag reports: DIAG-SUMMARY on -> " + r);
        return r;
    }

    private static String offRequest() {
        String r = DaemonSocket.roundTrip("DIAG-SUMMARY\noff\n", 15000);
        android.util.Log.i("NowhereChooser", "diag reports: DIAG-SUMMARY off -> " + r);
        return r;
    }

    /** One scheduled report: the by-hand report's device keys plus {@code extra} (the tag, report_kind=scheduled), an
     *  empty note, no preview. One `OK <ticket>` / `ERR-...` line back; "" when it was not built. No ticket-table row. */
    private static String sendScheduled(Context ctx, Map<String, String> extra) {
        String reply;
        try {
            org.json.JSONObject o = new org.json.JSONObject();
            o.put("note", "");
            o.put("preview", false);
            org.json.JSONObject st = ProfileActivity.reportStatus(ctx);
            for (Map.Entry<String, String> e : extra.entrySet()) st.put(e.getKey(), e.getValue());
            // NWP-20261202-08: the run record up to this run's send (its send line is written after the reply).
            for (Map.Entry<String, String> e : DiagReports.jobStatus(readFile(ctx, DiagReports.RUNS_FILE),
                    System.currentTimeMillis(), pending(ctx)).entrySet()) st.put(e.getKey(), e.getValue());
            o.put("status", st);
            reply = DaemonSocket.roundTrip("REPORT-ISSUE\n" + o.toString() + "\n", 120000);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "diag reports: report not built (" + t.getClass().getSimpleName() + ")");
            return "";
        }
        boolean ok = reply.startsWith("OK ");
        android.util.Log.i("NowhereChooser", "diag reports: scheduled report " + (ok ? "sent" : "not sent ("
                + reply.split(" ", 2)[0] + ")"));
        return reply;
    }

    /** {online, onWifi}: online = the active network has INTERNET and VALIDATED; onWifi = online and NOT_METERED. */
    private static boolean[] netState(Context ctx) {
        try {
            android.net.ConnectivityManager cm = ctx.getSystemService(android.net.ConnectivityManager.class);
            android.net.Network nw = cm == null ? null : cm.getActiveNetwork();
            android.net.NetworkCapabilities nc = nw == null ? null : cm.getNetworkCapabilities(nw);
            if (nc == null) return new boolean[] {false, false};
            boolean online = nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    && nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            return new boolean[] {online,
                    online && nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)};
        } catch (Throwable t) {
            return new boolean[] {false, false};
        }
    }
}
