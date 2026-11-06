package com.nowhere.push;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The UnifiedPush distributor's connection holder (#157). Holds one long-lived SSE stream to the gateway
 * ({@code POST /push/stream}, tokens in the JSON body with the stream secret of each registration that has one
 * (dn-1102 #5); the GET form, which carries no secret, only as the fallback for an older gateway)
 * covering every current registration; on a streamed push it broadcasts a MESSAGE to the owning app. On REGISTER it mints a gateway endpoint ({@code POST /push/register}) and
 * hands it back via NEW_ENDPOINT. A {@code gone: <token>} line from the gateway (it forgot that endpoint) re-mints that
 * registration's endpoint on exec and hands the app the new one. Amnesiac: runs in the roamed session, dies on logoff, and the gateway
 * queues meanwhile -- the backlog drains when the app re-registers on the next login. All state mutation
 * is serialized on {@link #exec}; only the SSE read runs on its own thread. The gateway (and this service)
 * only ever handle RFC 8291 webpush ciphertext -- never plaintext.
 */
public class PushService extends Service {
    private static final String TAG = "NowherePush";
    private static final String CHANNEL = "nowhere_push";
    private static final int NOTIF_ID = 1;
    private static final String FILE = "registrations.json";
    private static final String DEFAULT_GATEWAY = "https://api.nowhere.mobile";
    // The SSE read timeout: three of the gateway's 25 s keep-alive pings (nowhere-cloud internal/gateway/push.go
    // pushKeepAlive), so two lost pings are tolerated. The two must move together. Silence this long means the path died
    // without a FIN/RST, and the SocketTimeoutException drops into the backoff and reconnect.
    private static final int STREAM_READ_TIMEOUT_MS = 75_000;

    private static final String EXTRA_OP = "op";
    private static final String OP_REGISTER = "register";
    private static final String OP_UNREGISTER = "unregister";
    private static final String X_APP = "app";
    private static final String X_APPTOKEN = "appToken";

    private final ExecutorService exec = Executors.newSingleThreadExecutor();
    private final Map<String, Reg> regs = new LinkedHashMap<>(); // appToken -> Reg (touched only on exec)

    private volatile HttpURLConnection streamConn;
    private volatile Thread streamThread;
    private volatile boolean stopping = false;
    private volatile boolean streamGetOnly; // a gateway answered the POST 404/405: GET form for the rest of this process

    static final class Reg {
        final String appPackage, appToken, gatewayToken, endpoint;
        final String secret; // the stream secret /push/register returned (dn-1102 #5); null for one minted before it
        Reg(String p, String t, String g, String e) {
            this(p, t, g, e, null);
        }
        Reg(String p, String t, String g, String e, String s) {
            appPackage = p;
            appToken = t;
            gatewayToken = g;
            endpoint = e;
            secret = s;
        }
    }

    // ---- entry points from the receiver ----
    static void enqueueRegister(Context ctx, String appPackage, String appToken) {
        startFg(ctx, new Intent(ctx, PushService.class)
                .putExtra(EXTRA_OP, OP_REGISTER).putExtra(X_APP, appPackage).putExtra(X_APPTOKEN, appToken));
    }

    static void enqueueUnregister(Context ctx, String appToken) {
        startFg(ctx, new Intent(ctx, PushService.class)
                .putExtra(EXTRA_OP, OP_UNREGISTER).putExtra(X_APPTOKEN, appToken));
    }

    private static void startFg(Context ctx, Intent i) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i);
        else ctx.startService(i);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        startForegroundNotif();
        exec.execute(() -> {
            loadRegs();
            reconnectStream();
        });
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForegroundNotif(); // ensure the FGS notification on every (re)delivery
        if (intent != null) {
            final String op = intent.getStringExtra(EXTRA_OP);
            final String app = intent.getStringExtra(X_APP);
            final String appToken = intent.getStringExtra(X_APPTOKEN);
            if (OP_REGISTER.equals(op) && app != null && appToken != null) {
                exec.execute(() -> handleRegister(app, appToken));
            } else if (OP_UNREGISTER.equals(op) && appToken != null) {
                exec.execute(() -> handleUnregister(appToken));
            }
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopping = true;
        closeStream();
        exec.shutdownNow();
        super.onDestroy();
    }

    // ---- control ops (serialized on exec) ----
    private void handleRegister(String appPackage, String appToken) {
        try {
            Reg existing = regs.get(appToken);
            if (existing != null && existing.appPackage.equals(appPackage)) {
                broadcastNewEndpoint(existing); // idempotent re-register -> same endpoint, no new gw token
                return;
            }
            String[] ep = gatewayRegister(); // [endpoint, gatewayToken, secret]
            if (ep == null) {
                broadcastRegistrationFailed(appPackage, appToken, "gateway unreachable");
                return;
            }
            Reg r = new Reg(appPackage, appToken, ep[1], ep[0], ep[2]);
            regs.put(appToken, r);
            saveRegs();
            broadcastNewEndpoint(r);
            reconnectStream();
            Log.i(TAG, "registered " + appPackage + " -> endpoint minted");
        } catch (Throwable t) {
            Log.w(TAG, "handleRegister", t);
            broadcastRegistrationFailed(appPackage, appToken, "error");
        }
    }

    private void handleUnregister(String appToken) {
        Reg r = regs.remove(appToken);
        if (r == null) return;
        saveRegs();
        gatewayUnregister(r.gatewayToken, r.secret);
        broadcastUnregistered(r);
        reconnectStream();
        Log.i(TAG, "unregistered " + r.appPackage);
        if (regs.isEmpty()) stopSelf(); // nothing left to hold a connection for
    }

    // ---- SSE stream (rebuilt whenever the registration set changes) ----
    private void reconnectStream() {
        closeStream();
        if (stopping || regs.isEmpty()) return;
        final List<String> tokens = new ArrayList<>();
        final Map<String, Reg> byGw = new LinkedHashMap<>();
        for (Reg r : regs.values()) {
            tokens.add(r.gatewayToken);
            byGw.put(r.gatewayToken, r);
        }
        Thread th = new Thread(() -> streamLoop(tokens, byGw), "push-sse");
        th.setDaemon(true);
        streamThread = th;
        th.start();
    }

    private void closeStream() {
        HttpURLConnection c;
        Thread t;
        // One step with streamLoop's publish below: a loop that has not yet published its connection sees the cleared
        // streamThread and abandons it, so no connection opened after this call can outlive it.
        synchronized (this) {
            c = streamConn;
            streamConn = null;
            t = streamThread;
            streamThread = null;
        }
        if (c != null) try {
            c.disconnect();
        } catch (Throwable ignore) {
        }
        if (t != null) t.interrupt();
    }

    /** Appends s as a JSON string: quoted, with '"', '\' and control characters escaped. */
    static void jsonString(StringBuilder sb, String s) {
        sb.append('"');
        for (int j = 0; j < s.length(); j++) {
            char ch = s.charAt(j);
            switch (ch) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                default:
                    if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
                    else sb.append(ch);
            }
        }
        sb.append('"');
    }

    /**
     * The POST body as UTF-8, hand-escaped so the bytes are exact and need no org.json: {"tokens":["t1","t2"]}, plus
     * "secrets":{"t1":"s1"} for each token whose registration has a stream secret (dn-1102 #5), in token order. With
     * none it is the tokens-only body, byte for byte.
     */
    static byte[] streamBody(List<String> tokens, Map<String, Reg> byGw) {
        StringBuilder sb = new StringBuilder("{\"tokens\":[");
        for (int i = 0; i < tokens.size(); i++) {
            if (i > 0) sb.append(',');
            jsonString(sb, tokens.get(i));
        }
        sb.append(']');
        boolean any = false;
        for (String t : tokens) {
            Reg r = byGw.get(t);
            if (r == null || r.secret == null || r.secret.isEmpty()) continue; // never a "": the gateway refuses it
            sb.append(any ? "," : ",\"secrets\":{");
            any = true;
            jsonString(sb, t);
            sb.append(':');
            jsonString(sb, r.secret);
        }
        if (any) sb.append('}');
        return sb.append('}').toString().getBytes(StandardCharsets.UTF_8);
    }

    /** Only an older gateway's answer to the POST: 404 (it routes to POST /push/{token}) or 405. Never 400/413/5xx. */
    static boolean shouldFallBackToGet(int code) {
        return code == 404 || code == 405;
    }

    private HttpURLConnection openStream(String url) throws Exception {
        return (HttpURLConnection) new URL(url).openConnection();
    }

    private void streamLoop(List<String> tokens, Map<String, Reg> byGw) {
        final Thread self = Thread.currentThread();
        long backoff = 2000;
        while (!stopping && self == streamThread) {
            HttpURLConnection c = null;
            try {
                boolean useGet = streamGetOnly;
                if (!useGet) {
                    // The tokens travel in the request body: nothing token-shaped in the URL or a header, so no
                    // access log on the path records the profile's token set at every reconnect. The stream secrets
                    // ride in the body too, never in a URL (dn-1102 #5).
                    byte[] body = streamBody(tokens, byGw);
                    c = openStream(gatewayBase() + "/push/stream");
                    c.setRequestMethod("POST");
                    c.setRequestProperty("Content-Type", "application/json");
                    c.setRequestProperty("Accept", "text/event-stream");
                    c.setDoOutput(true);
                    c.setFixedLengthStreamingMode(body.length);
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(STREAM_READ_TIMEOUT_MS);
                    synchronized (this) {
                        if (stopping || self != streamThread) return; // closeStream ran first: leave c unopened
                        streamConn = c;
                    }
                    try (OutputStream os = c.getOutputStream()) {
                        // getOutputStream connects, and a disconnect that landed before it cannot undo that. The check and
                        // the write share one monitor hold, so a closeStream either ran first (nothing is written) or
                        // waits until the write is done and then cuts the connection: it never returns mid-write.
                        synchronized (this) {
                            if (streamConn != c) return;
                            os.write(body);
                        }
                    }
                    int code = c.getResponseCode();
                    if (shouldFallBackToGet(code)) {
                        // An older gateway routes the POST to POST /push/{token} (404) or lacks the method (405).
                        streamGetOnly = true;
                        useGet = true;
                        Log.w(TAG, "gateway has no POST /push/stream (HTTP " + code + "); using the GET form");
                        c.disconnect();
                        c = null;
                    }
                }
                if (useGet) {
                    StringBuilder q = new StringBuilder();
                    for (int i = 0; i < tokens.size(); i++) {
                        if (i > 0) q.append(',');
                        q.append(URLEncoder.encode(tokens.get(i), "UTF-8"));
                    }
                    c = openStream(gatewayBase() + "/push/stream?tokens=" + q);
                    c.setRequestProperty("Accept", "text/event-stream");
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(STREAM_READ_TIMEOUT_MS);
                    synchronized (this) {
                        // closeStream can land between the POST's 404/405 and here; it cannot cancel a connection it never saw
                        if (stopping || self != streamThread) return;
                        streamConn = c;
                    }
                    c.connect();
                    // Same as the POST: a closeStream between the publish and connect() disconnected a connection
                    // that was not yet open, so connect() just opened it. Drop it before the request is sent.
                    synchronized (this) {
                        if (streamConn != c) return;
                    }
                }
                if (c.getResponseCode() != 200) throw new Exception("stream code " + c.getResponseCode());
                backoff = 2000; // healthy connection -> reset backoff
                BufferedReader br = new BufferedReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8));
                final Set<String> seen = new HashSet<>(); // the gone tokens this connection already handed to exec
                String line;
                while ((line = br.readLine()) != null) {
                    if (self != streamThread) break;
                    if (line.startsWith("data: ")) handleSseData(line.substring(6), byGw);
                    else if (line.startsWith("gone: ")) onGone(line.substring(6).trim(), byGw, seen);
                }
            } catch (Throwable t) {
                if (stopping || self != streamThread) return;
                Log.w(TAG, "sse stream dropped, retrying", t);
            } finally {
                if (c != null) try {
                    c.disconnect();
                } catch (Throwable ignore) {
                }
            }
            if (stopping || self != streamThread) return;
            try {
                Thread.sleep(backoff);
            } catch (InterruptedException e) {
                return;
            }
            backoff = Math.min(backoff * 2, 60000);
        }
    }

    private void handleSseData(String json, Map<String, Reg> byGw) {
        try {
            JSONObject o = new JSONObject(json);
            Reg r = byGw.get(o.optString("token", ""));
            if (r == null) return; // not one of ours (or stale)
            broadcastMessage(r, Base64.decode(o.optString("message", ""), Base64.DEFAULT));
        } catch (Throwable t) {
            Log.w(TAG, "bad sse data", t);
        }
    }

    /**
     * The gateway names each presented token it holds no endpoint for (a restart, its 24 h reap, an unregister) in a
     * {@code gone: <token>} block at the head of the stream (nowhere-cloud NWC-20261104-02). Runs on the stream
     * thread: no network and no registration state here, only a hand-off to exec, once per token per connection.
     */
    private void onGone(String gwToken, Map<String, Reg> byGw, Set<String> seen) {
        final Reg r = byGw.get(gwToken);
        if (r == null) return; // not one of ours (or stale)
        if (!seen.add(gwToken)) return; // already handed off on this connection
        exec.execute(() -> remint(r));
    }

    /**
     * On exec: mint a new gateway endpoint for a registration the gateway forgot and hand it to the app, as a first
     * register does. The old endpoint is not unregistered: the gateway already forgot it. On failure the registration
     * keeps its token, and the next connection reports it gone again (the stream backoff bounds the retries).
     * Logs the package only, never a token or an endpoint (Q110).
     */
    private void remint(Reg old) {
        try {
            if (regs.get(old.appToken) != old) return; // re-registered, unregistered or re-minted since the line was read
            String[] ep = gatewayRegister(); // [endpoint, gatewayToken, secret]
            if (ep == null) {
                Log.w(TAG, "re-mint failed for " + old.appPackage + "; retried when the gateway reports it gone again");
                return;
            }
            Reg nr = new Reg(old.appPackage, old.appToken, ep[1], ep[0], ep[2]);
            regs.put(nr.appToken, nr);
            saveRegs();
            broadcastNewEndpoint(nr);
            reconnectStream();
            Log.i(TAG, "re-minted " + old.appPackage + ": the gateway no longer knew its endpoint");
        } catch (Throwable t) {
            Log.w(TAG, "re-mint " + old.appPackage + ": " + t.getClass().getSimpleName());
        }
    }

    // ---- gateway HTTP ----
    private String gatewayBase() {
        String p = "";
        try {
            p = android.os.SystemProperties.get("persist.nowhere.gateway_url", "");
        } catch (Throwable ignore) {
        }
        String base = (p != null && !p.isEmpty()) ? p : DEFAULT_GATEWAY;
        return base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
    }

    /**
     * A /push/register answer -> [endpoint, gatewayToken, secret], or null without an endpoint or a token. An absent or
     * "" secret (an older gateway) is null.
     */
    static String[] parseRegister(String json) throws Exception {
        JSONObject o = new JSONObject(json);
        String endpoint = o.optString("endpoint", "");
        String token = o.optString("token", "");
        String secret = o.optString("secret", "");
        if (endpoint.isEmpty() || token.isEmpty()) return null;
        return new String[]{endpoint, token, secret.isEmpty() ? null : secret};
    }

    /** POST /push/register -> {endpoint, token, secret}. Returns [endpoint, gatewayToken, secret] or null. */
    private String[] gatewayRegister() {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(gatewayBase() + "/push/register").openConnection();
            c.setRequestMethod("POST");
            c.setConnectTimeout(15000);
            c.setReadTimeout(15000);
            c.setDoOutput(true);
            c.getOutputStream().close(); // empty body
            if (c.getResponseCode() != 200) return null;
            return parseRegister(readAll(c.getInputStream()));
        } catch (Throwable t) {
            // the class only: Android's JSONException message holds the whole answer, the token and secret included
            Log.w(TAG, "gatewayRegister: " + t.getClass().getSimpleName());
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    /** The POST /push/unregister body: {"token":"t"}, plus "secret":"s" when the registration has one (dn-1102 #5). */
    static byte[] unregisterBody(String gwToken, String secret) {
        StringBuilder sb = new StringBuilder("{\"token\":");
        jsonString(sb, gwToken);
        if (secret != null) {
            sb.append(",\"secret\":");
            jsonString(sb, secret);
        }
        return sb.append('}').toString().getBytes(StandardCharsets.UTF_8);
    }

    private void gatewayUnregister(String gwToken, String secret) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(gatewayBase() + "/push/unregister").openConnection();
            c.setRequestMethod("POST");
            c.setConnectTimeout(15000);
            c.setReadTimeout(15000);
            c.setRequestProperty("Content-Type", "application/json");
            c.setDoOutput(true);
            byte[] body = unregisterBody(gwToken, secret);
            OutputStream os = c.getOutputStream();
            os.write(body);
            os.close();
            c.getResponseCode(); // fire-and-forget
        } catch (Throwable t) {
            Log.w(TAG, "gatewayUnregister", t);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    // ---- broadcasts to apps ----
    private void broadcastNewEndpoint(Reg r) {
        Intent i = new Intent(DistributorReceiver.ACTION_NEW_ENDPOINT).setPackage(r.appPackage)
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        i.putExtra(DistributorReceiver.EXTRA_TOKEN, r.appToken);
        i.putExtra(DistributorReceiver.EXTRA_ENDPOINT, r.endpoint);
        sendBroadcast(i);
    }

    private void broadcastRegistrationFailed(String appPackage, String appToken, String reason) {
        Intent i = new Intent(DistributorReceiver.ACTION_REGISTRATION_FAILED).setPackage(appPackage)
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        i.putExtra(DistributorReceiver.EXTRA_TOKEN, appToken);
        i.putExtra(DistributorReceiver.EXTRA_REASON, reason);
        sendBroadcast(i);
    }

    private void broadcastUnregistered(Reg r) {
        Intent i = new Intent(DistributorReceiver.ACTION_UNREGISTERED).setPackage(r.appPackage)
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        i.putExtra(DistributorReceiver.EXTRA_TOKEN, r.appToken);
        sendBroadcast(i);
    }

    private void broadcastMessage(Reg r, byte[] payload) {
        Intent i = new Intent(DistributorReceiver.ACTION_MESSAGE).setPackage(r.appPackage)
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        i.putExtra(DistributorReceiver.EXTRA_TOKEN, r.appToken);
        i.putExtra(DistributorReceiver.EXTRA_BYTES_MESSAGE, payload); // byte[]: opaque webpush ciphertext
        i.putExtra(DistributorReceiver.EXTRA_MESSAGE_ID, Long.toString(System.nanoTime()));
        sendBroadcast(i);
    }

    // ---- registration persistence (survives a mid-session service restart) ----
    /** One registrations.json object -> Reg. One written before dn-1102 #5 has no "secret" and loads null, as does "". */
    static Reg regFromJson(JSONObject o) throws JSONException {
        String s = o.has("secret") ? o.getString("secret") : "";
        return new Reg(o.getString("app"), o.getString("appToken"), o.getString("gw"), o.getString("endpoint"),
                s.isEmpty() ? null : s);
    }

    /** Reg -> one registrations.json object; "secret" only when the registration has one. */
    static JSONObject regToJson(Reg r) throws JSONException {
        JSONObject o = new JSONObject().put("app", r.appPackage).put("appToken", r.appToken)
                .put("gw", r.gatewayToken).put("endpoint", r.endpoint);
        if (r.secret != null) o.put("secret", r.secret);
        return o;
    }

    private void loadRegs() {
        try {
            File f = new File(getFilesDir(), FILE);
            if (!f.exists()) return;
            JSONArray a = new JSONArray(readAll(new FileInputStream(f)));
            for (int i = 0; i < a.length(); i++) {
                Reg r = regFromJson(a.getJSONObject(i));
                regs.put(r.appToken, r);
            }
            Log.i(TAG, "loaded " + regs.size() + " registration(s)");
        } catch (Throwable t) {
            // the class only: Android's JSONException message holds the whole file, every token and secret included
            Log.w(TAG, "loadRegs: " + t.getClass().getSimpleName());
        }
    }

    private void saveRegs() {
        try {
            JSONArray a = new JSONArray();
            for (Reg r : regs.values()) {
                a.put(regToJson(r));
            }
            PrintWriter w = new PrintWriter(new File(getFilesDir(), FILE), "UTF-8");
            w.print(a.toString());
            w.close();
        } catch (Throwable t) {
            Log.w(TAG, "saveRegs", t);
        }
    }

    private static String readAll(InputStream in) throws Exception {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
        in.close();
        return new String(bo.toByteArray(), StandardCharsets.UTF_8);
    }

    // ---- foreground service notification (mandatory for the persistent connection) ----
    private void startForegroundNotif() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm != null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Push", NotificationManager.IMPORTANCE_MIN);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("Push active")
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }
}
