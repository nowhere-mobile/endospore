#!/usr/bin/env bash
# test-push-stream.sh [--mutate] -- NWP-20261016-23: NowherePush's SSE stream reconnects after a SILENT connection.
# Lifts PushService.streamLoop + handleSseData + the STREAM_READ_TIMEOUT_MS line VERBATIM (by signature) into a harness
# class and EXECUTES them under a real JVM against a local ServerSocket. Stubs: android.util.Log, android.util.Base64
# (over java.util.Base64) and a tiny org.json.JSONObject stand-in (flat string fields only; no org.json jar is assumed on
# the VM). gatewayBase() points at the harness server and broadcastMessage records into a list.
#
# WHY THIS IS COMMITTED. The stream was opened with setReadTimeout(0), so when the path died without a FIN or RST (NAT
# expiry, Wi-Fi -> cellular, a carrier dropping an idle flow) readLine() blocked forever and the reconnect/backoff loop
# never ran; no UnifiedPush app in the session got another push. The gateway pings every 25 s (push.go pushKeepAlive) and the
# client now treats three missed pings (75 s) as a dead path. The harness shrinks the constant (asserting the rewrite applied).
#
# NWP-20261019-08: the stream is a POST whose JSON body carries the tokens (nothing token-shaped in the URL or a header);
# an older gateway answering 404/405 is a one-way switch to the GET ?tokens= form. streamBody, shouldFallBackToGet and the
# streamGetOnly field are lifted too.
#
# Cases: (a) a 200 + one ping, then SILENCE without closing, is followed by a second connection within timeout + the first
# backoff; (b) a data line for our token broadcasts the decoded bytes once, a foreign token none; (c) a 500 is retried after
# the backoff; (d) the stop flag / a replaced streamThread ends the loop with no further connection; (e) a healthy connect
# resets the backoff (two silent connections in a row each wait the FIRST backoff, not a doubled one).
# (f) the POST: request line, no query, JSON content type, EXACT body, no token in a header, data broadcast once; (g)/(h) a
# 404/405 falls back to GET in the same iteration and stays on GET after a drop; (i) a 400 then a 500 never fall back; (j) the
# body bytes for 0/1/3 tokens and escaping, and shouldFallBackToGet's truth table.
# (k) a closeStream landing in the 404 -> GET handoff leaves no connection open (closeStream is lifted too).
# (l)/(m) a closeStream between a connection's publish and its open (GET / POST) sends no request body or GET and ends the loop.
# (n) a closeStream after the ownership check, as the POST body write begins, delivers no token and ends the loop.
# (o) a closeStream from another thread during the body write does not return until that write is done: (o1) the body
# write runs with the Pump's monitor held (Thread.holdsLock); (o2) the writer waits until the closer is BLOCKED on that
# monitor with the writer as owner, or has returned, and the closer must return only after the write; (o3a)/(o3b) repeat
# (o1)/(o2) with the closer stalled 1 s. Every wait ends on an event, so the case is deterministic by construction (backlog
# section E, "`core/pushd/test-push-stream.sh --mutate` leaves “the body written outside the ownership monitor” unconvicted
# under CI load").
# (b)-(d) are coverage and pass on origin/main too; (a) and (e) need the timeout and fail there.
#
# NWP-20261106-10: the gateway names each presented token it holds no endpoint for in a `gone: <token>` block at the head of
# the stream (nowhere-cloud NWC-20261104-02); onGone and remint are lifted too, and the phone re-mints that registration on
# exec. `exec` here is a RECORDING executor: it counts execute() and runs each task on its own thread named "exec", so a
# re-mint run on the stream thread is detectable. On origin/main the lift of onGone/remint fails (exit 2, EXTRACTION FAILED);
# the "gone: dispatch line dropped" mutant (a build that has the methods but never calls them) fails (p), (r), (s), (t), (u) and
# (v); (q) passes there (coverage, like (b)-(d)).
# (p) a `gone:` line for our token: one execute, one gatewayRegister on the exec thread, one NEW_ENDPOINT broadcast carrying the
# new endpoint, regs updated and saved, one reconnect; (q) a foreign token does nothing; (r) two lines for one token in one
# connection re-mint once; (s) a failed mint leaves regs, broadcast and save alone; (t) a data line in the same stream still
# broadcasts once; (u) no log message holds a token, an endpoint or a secret; (v) a Reg replaced before the task runs is not
# re-minted.
#
# NWP-20261115-02: each registration keeps the stream secret /push/register returned (dn-1102 #5), and the POST body presents
# it. The escaper is its own method now, so jsonString is lifted too, and streamBody takes the byGw map. (j) keeps its exact
# bytes with secret-less registrations. (w) a Reg with a secret and one without: the server receives exactly
# {"tokens":["gwtok-a","gwtok-b"],"secrets":{"gwtok-a":"sec-a-7q"}}; (x) a `gone:` re-mint answered with a new secret leaves
# regs holding it. On origin/main the lift of jsonString fails (exit 2, EXTRACTION FAILED). The S4 mutant (remint passes null
# for the new secret) fails (x); the "streamLoop sends no secrets" mutant fails (w). test-push-secret.sh covers the other helpers.
#
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#   bash test-push-stream.sh            # the cases
#   bash test-push-stream.sh --mutate   # ... plus mutants that must each be CONVICTED
# Exit: 0 pass, 1 a case failed, 2 cannot run (no JDK, EXTRACTION FAILED), 3 the harness does not compile.
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${PUSH_SERVICE_SRC:-$ROOT/core/pushd/src/com/nowhere/push/PushService.java}
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-push-stream: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-XX:-UsePerfData -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

lift(){ # lift <signature prefix> <file>: from the signature line to the first 4-space-indented closing brace
  awk -v sig="$1" 'index($0,sig)==1{p=1} p{print} p&&$0=="    }"{exit}' "$2"
}

# run_one <PushService.java> [sed script applied to the LIFTED code after the timeout rewrite] -> harness exit status
run_one(){
  local src=$1 mut=${2:-} d; d=$(mktemp -d -p "$W")
  [ -f "$src" ] || { echo "EXTRACTION FAILED: no $src" >&2; return 2; }
  lift '    private void streamLoop(' "$src" >"$d/loop.txt"
  lift '    private void handleSseData(' "$src" >"$d/data.txt"
  lift '    private void onGone(' "$src" >"$d/gone.txt"
  lift '    private void remint(' "$src" >"$d/remint.txt"
  lift '    private void closeStream(' "$src" >"$d/close.txt"
  lift '    static void jsonString(' "$src" >"$d/json.txt"
  lift '    static byte[] streamBody(' "$src" >"$d/body.txt"
  lift '    static boolean shouldFallBackToGet(' "$src" >"$d/fb.txt"
  grep -E '^    private volatile boolean streamGetOnly;' "$src" >"$d/field.txt"
  grep -E '^    (private )?static final int STREAM_READ_TIMEOUT_MS = 75_000;' "$src" >"$d/const.txt"
  for f in loop data gone remint const json body fb field close; do
    [ -s "$d/$f.txt" ] || { echo "EXTRACTION FAILED: $f not found in $src" >&2; return 2; }
  done
  grep -q 'setReadTimeout(' "$d/loop.txt" || { echo "EXTRACTION FAILED: no setReadTimeout in streamLoop" >&2; return 2; }
  # shrink the timeout through the lifted constant, and prove the rewrite applied
  sed -i 's/STREAM_READ_TIMEOUT_MS = 75_000/STREAM_READ_TIMEOUT_MS = 600/' "$d/const.txt"
  grep -q 'STREAM_READ_TIMEOUT_MS = 600;' "$d/const.txt" || { echo "EXTRACTION FAILED: timeout rewrite did not apply" >&2; return 2; }
  if [ -n "$mut" ]; then
    cat "$d"/{loop,data,gone,remint,const,json,body,fb,field,close}.txt >"$d/before.txt"
    sed -i "$mut" "$d"/{loop,data,gone,remint,const,json,body,fb,field,close}.txt || return 2
    cat "$d"/{loop,data,gone,remint,const,json,body,fb,field,close}.txt | cmp -s - "$d/before.txt" && { echo "MUTATION INERT" >&2; return 2; }
  fi
  mkdir -p "$d/android/util" "$d/org/json"
  cat >"$d/android/util/Log.java" <<'J'
package android.util;
public final class Log {
    public static final java.util.List<String> msgs = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    public static int w(String t, String m, Throwable e) { msgs.add(t + ": " + m + " (" + e + ")"); System.out.println("    log W " + t + ": " + m + " (" + e + ")"); return 0; }
    /** Test hook: runs inside the lifted code's own Log.w(TAG, msg) call, i.e. at that exact point of streamLoop. */
    public static volatile Runnable onWarn;
    public static int w(String t, String m) { msgs.add(t + ": " + m); Runnable r = onWarn; if (r != null) r.run(); return 0; }
    public static int i(String t, String m) { msgs.add(t + ": " + m); return 0; }
}
J
  cat >"$d/android/util/Base64.java" <<'J'
package android.util;
public final class Base64 {
    public static final int DEFAULT = 0;
    public static byte[] decode(String s, int flags) { return java.util.Base64.getDecoder().decode(s); }
}
J
  cat >"$d/org/json/JSONException.java" <<'J'
package org.json;
public class JSONException extends Exception { public JSONException(String m) { super(m); } }
J
  cat >"$d/org/json/JSONObject.java" <<'J'
package org.json;
import java.util.*;
import java.util.regex.*;
/** Stand-in: a flat object of string fields, which is all the stream's data lines carry. */
public class JSONObject {
    private final Map<String, String> m = new HashMap<>();
    public JSONObject(String s) throws JSONException {
        if (s == null || !s.trim().startsWith("{")) throw new JSONException("not an object");
        Matcher x = Pattern.compile("\"([^\"]*)\"\\s*:\\s*\"([^\"]*)\"").matcher(s);
        while (x.find()) m.put(x.group(1), x.group(2));
    }
    public String optString(String k, String d) { return m.getOrDefault(k, d); }
}
J
  {
    cat <<'J'
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.io.OutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.*;
import android.util.Base64;
import android.util.Log;
import org.json.JSONObject;

final class Pump {
    private static final String TAG = "NowherePush";
    static final class Reg {
        final String appPackage, appToken, gatewayToken, endpoint;
        final String secret;
        Reg(String p, String t, String g, String e) { this(p, t, g, e, null); }
        Reg(String p, String t, String g, String e, String s) { appPackage = p; appToken = t; gatewayToken = g; endpoint = e; secret = s; }
    }
    volatile HttpURLConnection streamConn;
    volatile Thread streamThread;
    volatile boolean stopping = false;
    volatile int port;
    final List<String> got = Collections.synchronizedList(new ArrayList<>());
    private String gatewayBase() { return "http://127.0.0.1:" + port; }
    /** Test hook: runs once, inside the Nth connection's connect()/getOutputStream(), i.e. between publish and open. */
    volatile Runnable beforeOpen;
    volatile int openIdx = -1, opened = 0;
    /** Test hook: runs once as the Nth connection's body write begins, i.e. after the ownership check, before any byte is sent. */
    volatile Runnable beforeWrite;
    private HttpURLConnection openStream(String url) throws Exception {
        final HttpURLConnection d = (HttpURLConnection) new URL(url).openConnection();
        final int idx = opened++;
        return new HttpURLConnection(d.getURL()) {
            private void hook() { Runnable r = beforeOpen; if (r != null && idx == openIdx) { beforeOpen = null; r.run(); } }
            public void setRequestMethod(String m) throws java.net.ProtocolException { d.setRequestMethod(m); }
            public void setRequestProperty(String k, String v) { d.setRequestProperty(k, v); }
            public void setDoOutput(boolean b) { d.setDoOutput(b); }
            public void setFixedLengthStreamingMode(int n) { d.setFixedLengthStreamingMode(n); }
            public void setConnectTimeout(int t) { d.setConnectTimeout(t); }
            public void setReadTimeout(int t) { d.setReadTimeout(t); }
            public void connect() throws java.io.IOException { hook(); d.connect(); }
            public OutputStream getOutputStream() throws java.io.IOException {
                hook();
                final OutputStream o = d.getOutputStream();
                return new OutputStream() {
                    public void write(int b) throws java.io.IOException { pre(); o.write(b); }
                    public void write(byte[] b, int off, int len) throws java.io.IOException { pre(); o.write(b, off, len); }
                    public void flush() throws java.io.IOException { o.flush(); }
                    public void close() throws java.io.IOException { o.close(); }
                    private void pre() { Runnable r = beforeWrite; if (r != null && idx == openIdx) { beforeWrite = null; r.run(); } }
                };
            }
            public int getResponseCode() throws java.io.IOException { return d.getResponseCode(); }
            public java.io.InputStream getInputStream() throws java.io.IOException { return d.getInputStream(); }
            public void disconnect() { d.disconnect(); }
            public boolean usingProxy() { return false; }
        };
    }
    private void broadcastMessage(Reg r, byte[] payload) {
        got.add((r == null ? "<null>" : r.appToken) + "=" + new String(payload, StandardCharsets.ISO_8859_1));
    }
    final Map<String, Reg> regs = new LinkedHashMap<>();
    /** Recording executor: counts execute() and runs every task on its own NEW thread named "exec". */
    static final class RecExec implements java.util.concurrent.Executor {
        final java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
        final List<Thread> threads = Collections.synchronizedList(new ArrayList<>());
        public void execute(Runnable r) { calls.incrementAndGet(); Thread t = new Thread(r, "exec"); t.setDaemon(true); threads.add(t); t.start(); }
        void joinAll() throws InterruptedException { for (Thread t : new ArrayList<>(threads)) t.join(3000); }
    }
    final RecExec exec = new RecExec();
    volatile String[] mint; // gatewayRegister's scripted answer ([endpoint, gatewayToken, secret] or null)
    final List<String> regThreads = Collections.synchronizedList(new ArrayList<>());
    final List<String> newEps = Collections.synchronizedList(new ArrayList<>());
    final java.util.concurrent.atomic.AtomicInteger saves = new java.util.concurrent.atomic.AtomicInteger(), reconnects = new java.util.concurrent.atomic.AtomicInteger();
    private String[] gatewayRegister() { regThreads.add(Thread.currentThread().getName()); return mint; }
    private void saveRegs() { saves.incrementAndGet(); }
    private void broadcastNewEndpoint(Reg r) { newEps.add(r.appToken + "=" + r.endpoint); }
    private void reconnectStream() { reconnects.incrementAndGet(); }
J
    cat "$d/field.txt" "$d/const.txt" "$d/json.txt" "$d/body.txt" "$d/fb.txt" "$d/data.txt" "$d/gone.txt" "$d/remint.txt" "$d/close.txt" "$d/loop.txt"
    echo '    void runLoop(List<String> tokens, Map<String, Reg> byGw) { streamLoop(tokens, byGw); }'
    echo "    void closeNow() { closeStream(); }"
    echo "}"
    cat <<'J'
public final class Harness {
    static int pass, fail;
    static void check(String name, boolean ok, String why) {
        if (ok) { pass++; System.out.println("  ok    " + name); } else { fail++; System.out.println("  FAIL  " + name + " -- " + why); }
    }
    /** A scripted gateway: behaviour(idx) decides the answer to the idx-th connection. */
    interface Behave { void run(int idx, java.io.OutputStream out, java.net.Socket s) throws Exception; }
    static final class Srv {
        final java.net.ServerSocket ss;
        final List<Long> starts = Collections.synchronizedList(new ArrayList<>());
        final List<java.net.Socket> socks = Collections.synchronizedList(new ArrayList<>());
        final Map<Integer, String> reqLine = Collections.synchronizedMap(new HashMap<>());
        final Map<Integer, String> heads = Collections.synchronizedMap(new HashMap<>());
        final Map<Integer, byte[]> bodies = Collections.synchronizedMap(new HashMap<>());
        Srv(Behave b) throws Exception {
            ss = new java.net.ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"));
            Thread t = new Thread(() -> {
                try {
                    while (true) {
                        final java.net.Socket s = ss.accept();
                        final int idx;
                        synchronized (starts) { idx = starts.size(); starts.add(System.nanoTime() / 1_000_000); }
                        socks.add(s);
                        Thread h = new Thread(() -> {
                            try {
                                java.io.InputStream in = s.getInputStream();
                                java.io.ByteArrayOutputStream hb = new java.io.ByteArrayOutputStream();
                                int a = 0, c; // read up to the blank line ending the request head
                                while (a < 4 && (c = in.read()) >= 0) { hb.write(c); a = (c == '\r' || c == '\n') ? a + 1 : 0; }
                                String[] lines = new String(hb.toByteArray(), StandardCharsets.ISO_8859_1).split("\r\n");
                                int clen = 0;
                                StringBuilder hs = new StringBuilder();
                                for (int li = 1; li < lines.length; li++) {
                                    hs.append(lines[li]).append('\n');
                                    if (lines[li].toLowerCase().startsWith("content-length:")) clen = Integer.parseInt(lines[li].substring(15).trim());
                                }
                                byte[] body = new byte[clen];
                                for (int got = 0; got < clen; ) { int r = in.read(body, got, clen - got); if (r < 0) break; got += r; }
                                reqLine.put(idx, lines[0]); heads.put(idx, hs.toString()); bodies.put(idx, body);
                                b.run(idx, s.getOutputStream(), s);
                            } catch (Exception ignore) { }
                        });
                        h.setDaemon(true);
                        h.start();
                    }
                } catch (Exception ignore) { }
            });
            t.setDaemon(true);
            t.start();
        }
        int n() { return starts.size(); }
        long at(int i) { return starts.get(i); }
        // A connection counts once its request is recorded, not when it is accepted: the handler parses the request
        // after the accept, so a check reading reqLine.get(i) straight after waitFor saw null on a loaded host
        // ((g)2/(h)2/(i), 2 runs in 3 with every core busy, NWP-20261021-26). at(i) is still the accept time.
        boolean ready(int count) {
            if (n() < count) return false;
            for (int i = 0; i < count; i++) if (!reqLine.containsKey(i)) return false;
            return true;
        }
        boolean waitFor(int count, long ms) throws Exception {
            long end = System.currentTimeMillis() + ms;
            while (System.currentTimeMillis() < end) { if (ready(count)) return true; Thread.sleep(20); }
            return ready(count);
        }
        void close() { try { ss.close(); } catch (Exception ignore) { } for (java.net.Socket s : new ArrayList<>(socks)) try { s.close(); } catch (Exception ignore) { } }
    }
    static final String HEAD200 = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
    static void silent(java.io.OutputStream o, String first) throws Exception {
        o.write((HEAD200 + first).getBytes(StandardCharsets.UTF_8)); o.flush();
        Thread.sleep(120_000); // alive, mute, never closed: the path is dead without a FIN
    }
    static void refuse(java.io.OutputStream o, java.net.Socket k, int code) throws Exception {
        o.write(("HTTP/1.1 " + code + " X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes()); o.flush(); k.close();
    }
    static Pump start(Srv srv, Map<String, Pump.Reg> byGw) {
        final Pump p = new Pump();
        p.port = srv.ss.getLocalPort();
        final List<String> tokens = new ArrayList<>(byGw.keySet());
        Thread th = new Thread(() -> p.runLoop(tokens, byGw), "push-sse");
        th.setDaemon(true);
        p.streamThread = th;
        th.start();
        return p;
    }
    /** start(), with closeStream fired inside the idx-th connection's open (after it was published, before it is open). */
    static Thread start0(Pump p, Srv srv, Map<String, Pump.Reg> byGw, int idx) {
        p.port = srv.ss.getLocalPort();
        p.openIdx = idx;
        p.beforeOpen = () -> p.closeNow();
        final List<String> tokens = new ArrayList<>(byGw.keySet());
        Thread th = new Thread(() -> p.runLoop(tokens, byGw), "push-sse");
        th.setDaemon(true);
        p.streamThread = th;
        th.start();
        // closeStream can clear p.streamThread before start() returns. Keep the owned handle.
        return th;
    }
    /** start(), with regs and gatewayRegister's answer seeded BEFORE the stream thread starts. */
    static Pump startRegs(Srv srv, Map<String, Pump.Reg> byGw, Map<String, Pump.Reg> regs, String[] mint) {
        final Pump p = new Pump();
        p.port = srv.ss.getLocalPort();
        p.regs.putAll(regs);
        p.mint = mint;
        final List<String> tokens = new ArrayList<>(byGw.keySet());
        Thread th = new Thread(() -> p.runLoop(tokens, byGw), "push-sse");
        th.setDaemon(true);
        p.streamThread = th;
        th.start();
        return p;
    }
    /** Let the first connection's burst be read (< the 600 ms read timeout: no second connection), stop, join everything. */
    static void settle(Srv s, Pump p) throws Exception {
        s.waitFor(1, 3000); Thread.sleep(400);
        Thread th = p.streamThread; halt(p);
        if (th != null) { th.interrupt(); th.join(2000); }
        p.exec.joinAll();
    }
    static Map<String, Pump.Reg> ours() {
        Map<String, Pump.Reg> m = new LinkedHashMap<>();
        m.put("gwtok-ours", new Pump.Reg("org.example.app", "apptok", "gwtok-ours", "https://gw/ep"));
        return m;
    }
    static void halt(Pump p) { p.stopping = true; p.streamThread = null; }
    /** byGw for streamBody with every token a secret-less registration: the tokens-only body. */
    static Map<String, Pump.Reg> noSec(List<String> tokens) {
        Map<String, Pump.Reg> m = new LinkedHashMap<>();
        for (String t : tokens) m.put(t, new Pump.Reg("p", "t", t, "e"));
        return m;
    }
    static String body(List<String> tokens) { return new String(Pump.streamBody(tokens, noSec(tokens)), StandardCharsets.UTF_8); }

    public static void main(String[] args) throws Exception {
        Thread wd = new Thread(() -> {
            try { Thread.sleep(90_000); } catch (InterruptedException e) { return; }
            System.out.println("  FAIL  wall-clock limit (90 s) exceeded -- the harness would have hung");
            Runtime.getRuntime().halt(1);
        });
        wd.setDaemon(true);
        wd.start();
        final long T = 600, B1 = 2000, MARGIN = 1500;

        { // (a) silent connection -> a second connection within timeout + first backoff (+ margin)
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            Pump p = start(s, ours());
            boolean second = s.waitFor(2, T + B1 + MARGIN);
            check("(a) a silent connection is followed by a second one within timeout+backoff", second,
                  "only " + s.n() + " connection(s) after " + (T + B1 + MARGIN) + " ms: readLine() blocks forever");
            halt(p); s.close();
        }
        { // (b) our token delivers the decoded bytes once; a foreign token delivers none
            final String b64 = Base64.decode("AA==", 0).length == 1 ? java.util.Base64.getEncoder().encodeToString(new byte[]{'h', 'i', 0, (byte) 0xff}) : "";
            final String foreign = java.util.Base64.getEncoder().encodeToString("nope".getBytes(StandardCharsets.UTF_8));
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"
                + "data: {\"token\":\"gwtok-ours\",\"message\":\"" + b64 + "\"}\n\n"
                + "data: {\"token\":\"gwtok-other\",\"message\":\"" + foreign + "\"}\n\n"));
            Pump p = start(s, ours());
            Thread.sleep(700);
            List<String> g = new ArrayList<>(p.got);
            check("(b) our token broadcasts the decoded bytes exactly once, the foreign token none",
                  g.size() == 1 && g.get(0).equals("apptok=hi\u0000ÿ"), "broadcasts: " + g);
            halt(p); s.close();
        }
        { // (c) a 500 is retried after the backoff
            Srv s = new Srv((i, o, k) -> { o.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes()); o.flush(); k.close(); });
            Pump p = start(s, ours());
            boolean second = s.waitFor(2, B1 + MARGIN);
            long gap = second ? s.at(1) - s.at(0) : -1;
            check("(c) a 500 is retried after the first backoff", second && gap >= B1 - 200 && gap <= B1 + MARGIN, "second=" + second + " gap=" + gap + " ms");
            halt(p); s.close();
        }
        for (int mode = 0; mode < 2; mode++) { // (d) stopping ends the loop with no further connection
            Srv s = new Srv((i, o, k) -> { o.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes()); o.flush(); k.close(); });
            Pump p = start(s, ours());
            Thread th = p.streamThread;
            s.waitFor(1, 2000);
            Thread.sleep(150); // into the backoff sleep
            if (mode == 0) { p.stopping = true; th.interrupt(); } else { p.streamThread = null; th.interrupt(); }
            th.join(2000);
            Thread.sleep(B1 + 600);
            check("(d" + (mode + 1) + ") " + (mode == 0 ? "the stop flag + interrupt" : "a replaced streamThread") + " ends the loop with no further connection",
                  !th.isAlive() && s.n() == 1, "alive=" + th.isAlive() + " connections=" + s.n());
            halt(p); s.close();
        }
        { // (e) a healthy connect resets the backoff: the wait before connection 3 is the FIRST backoff, not the doubled one
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            Pump p = start(s, ours());
            boolean third = s.waitFor(3, 9000);
            long gap = third ? s.at(2) - s.at(1) : -1;
            check("(e) a healthy connect resets the backoff (connection 3 follows 2 within timeout+first backoff)",
                  third && gap <= T + B1 + MARGIN - 300, "third=" + third + " gap=" + gap + " ms (limit " + (T + B1 + MARGIN - 300) + ")");
            halt(p); s.close();
        }
        { // (f) the POST: request line, no query, JSON content type, EXACT body, no token in a header, data broadcast once
            final String b64 = java.util.Base64.getEncoder().encodeToString(new byte[]{'h', 'i'});
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n" + "data: {\"token\":\"gwtok-ours\",\"message\":\"" + b64 + "\"}\n\n"));
            Pump p = start(s, ours());
            s.waitFor(1, 3000); Thread.sleep(500);
            String rl = String.valueOf(s.reqLine.get(0)), hd = String.valueOf(s.heads.get(0));
            byte[] bd = s.bodies.get(0) == null ? new byte[0] : s.bodies.get(0);
            check("(f1) the first request line is POST /push/stream HTTP/1.1 with no query", rl.equals("POST /push/stream HTTP/1.1"), "request line: " + rl);
            check("(f2) Content-Type is application/json", hd.toLowerCase().contains("content-type: application/json"), "headers: " + hd);
            check("(f3) the body is exactly {\"tokens\":[\"gwtok-ours\"]}", Arrays.equals(bd, "{\"tokens\":[\"gwtok-ours\"]}".getBytes(StandardCharsets.UTF_8)), "body: " + new String(bd, StandardCharsets.ISO_8859_1));
            check("(f4) no header value contains a token", !hd.contains("gwtok"), "headers: " + hd);
            check("(f5) a data line on the stream is broadcast once", p.got.size() == 1 && p.got.get(0).equals("apptok=hi"), "broadcasts: " + p.got);
            halt(p); s.close();
        }
        for (int code : new int[]{404, 405}) { // (g)/(h) an older gateway: GET in the same iteration, GET again after a drop
            Srv s = new Srv((i, o, k) -> { if (i == 0) refuse(o, k, code); else silent(o, ": keep-alive\n\n"); });
            Pump p = start(s, ours());
            boolean third = s.waitFor(3, T + B1 + MARGIN + 1000);
            long gap = s.n() >= 2 ? s.at(1) - s.at(0) : -1;
            String r0 = String.valueOf(s.reqLine.get(0)), r1 = String.valueOf(s.reqLine.get(1)), r2 = String.valueOf(s.reqLine.get(2));
            String tag = code == 404 ? "(g)" : "(h)";
            check(tag + "1 a POST answered " + code + " is followed within 1 s by GET /push/stream?tokens=gwtok-ours",
                  r0.startsWith("POST /push/stream ") && r1.equals("GET /push/stream?tokens=gwtok-ours HTTP/1.1") && gap >= 0 && gap < 1000, "r0=" + r0 + " r1=" + r1 + " gap=" + gap);
            check(tag + "2 after that stream is dropped the reconnect is a GET again, never a second POST", third && r2.equals("GET /push/stream?tokens=gwtok-ours HTTP/1.1"), "third=" + third + " r2=" + r2);
            halt(p); s.close();
        }
        { // (i) a 400, then a 500: no GET is ever sent; the second attempt is a POST after the first backoff
            Srv s = new Srv((i, o, k) -> refuse(o, k, i == 0 ? 400 : 500));
            Pump p = start(s, ours());
            boolean second = s.waitFor(2, B1 + MARGIN);
            long gap = second ? s.at(1) - s.at(0) : -1;
            String r0 = String.valueOf(s.reqLine.get(0)), r1 = String.valueOf(s.reqLine.get(1));
            check("(i) a 400 then a 500 re-POST after the first backoff and never fall back to GET",
                  second && gap >= B1 - 200 && r0.startsWith("POST ") && r1.startsWith("POST "), "second=" + second + " gap=" + gap + " r0=" + r0 + " r1=" + r1);
            halt(p); s.close();
        }
        { // (j) the body bytes and the fall-back table
            String q = "a\"b\\c" + (char) 1;
            String ex = "{\"tokens\":[\"a\\\"b\\\\c\\" + "u0001\"]}";
            check("(j1) zero tokens", body(new ArrayList<>()).equals("{\"tokens\":[]}"), "got " + body(new ArrayList<>()));
            check("(j2) one token", body(Arrays.asList("t1")).equals("{\"tokens\":[\"t1\"]}"), "got " + body(Arrays.asList("t1")));
            check("(j3) three tokens, no whitespace", body(Arrays.asList("a", "b", "c")).equals("{\"tokens\":[\"a\",\"b\",\"c\"]}"), "got " + body(Arrays.asList("a", "b", "c")));
            check("(j4) quote, backslash and a 0x01 char are escaped", body(Arrays.asList(q)).equals(ex), "got " + body(Arrays.asList(q)) + " want " + ex);
            check("(j5) shouldFallBackToGet is true for 404 and 405 only",
                  Pump.shouldFallBackToGet(404) && Pump.shouldFallBackToGet(405) && !Pump.shouldFallBackToGet(200) && !Pump.shouldFallBackToGet(400)
                  && !Pump.shouldFallBackToGet(413) && !Pump.shouldFallBackToGet(500), "table wrong");
        }
        { // (k) closeStream landing in the 404 -> GET handoff (the "no POST /push/stream" log line): no GET is ever opened
            Srv s = new Srv((i, o, k) -> { if (i == 0) refuse(o, k, 404); else silent(o, ": keep-alive\n\n"); });
            // The hook is installed BEFORE the loop starts: set after start(), a slow main thread let the 404 warning fire
            // first, and the loop went on to the GET (seen in CI, NWP-20261115-02). Only the loop's own thread runs it.
            final Pump p = new Pump();
            p.port = s.ss.getLocalPort();
            final Map<String, Pump.Reg> kGw = ours();
            final List<String> toks = new ArrayList<>(kGw.keySet());
            final Thread th = new Thread(() -> p.runLoop(toks, kGw), "push-sse");
            th.setDaemon(true);
            android.util.Log.onWarn = () -> { if (Thread.currentThread() != th) return; android.util.Log.onWarn = null; p.closeNow(); };
            p.streamThread = th;
            th.start();
            s.waitFor(1, 3000);
            th.join(2000);
            Thread.sleep(700);
            android.util.Log.onWarn = null;
            check("(k) a closeStream during the 404 handoff ends the loop; no fallback GET is opened", !th.isAlive() && s.n() == 1,
                  "alive=" + th.isAlive() + " connections=" + s.n() + " second=" + s.reqLine.get(1));
            halt(p); s.close();
        }
        { // (l) closeStream between the GET's publish and its connect(): the connect opens it, so it must be dropped unsent
            Srv s = new Srv((i, o, k) -> { if (i == 0) refuse(o, k, 404); else silent(o, ": keep-alive\n\n"); });
            final Pump p = new Pump();
            final Thread th = start0(p, s, ours(), 1);
            s.waitFor(2, 3000);
            th.join(2000);
            Thread.sleep(500);
            check("(l) a closeStream between publish and connect() sends no fallback GET and ends the loop",
                  !th.isAlive() && (s.reqLine.get(1) == null || s.reqLine.get(1).isEmpty()), "alive=" + th.isAlive() + " second=" + s.reqLine.get(1));
            halt(p); s.close();
        }
        { // (m) the same on the POST: nothing token-shaped reaches the wire once closeStream has taken the connection
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            final Pump p = new Pump();
            final Thread th = start0(p, s, ours(), 0);
            s.waitFor(1, 3000);
            th.join(2000);
            Thread.sleep(500);
            String body = s.bodies.get(0) == null ? "" : new String(s.bodies.get(0), StandardCharsets.ISO_8859_1);
            check("(m) a closeStream between publish and the POST's open writes no token and ends the loop",
                  !th.isAlive() && !body.contains("gwtok"), "alive=" + th.isAlive() + " body=" + body);
            halt(p); s.close();
        }
        { // (n) closeStream AFTER the ownership check, as the body write begins: the published connection is cut, so no token is sent
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            final Pump p = new Pump();
            p.port = s.ss.getLocalPort();
            p.openIdx = 0;
            p.beforeWrite = () -> p.closeNow();
            final Map<String, Pump.Reg> byGw = ours();
            final List<String> tokens = new ArrayList<>(byGw.keySet());
            final Thread th = new Thread(() -> p.runLoop(tokens, byGw), "push-sse");
            th.setDaemon(true);
            p.streamThread = th;
            th.start();
            s.waitFor(1, 3000);
            th.join(2000);
            Thread.sleep(500);
            StringBuilder sb = new StringBuilder();
            for (byte[] bb : new ArrayList<byte[]>(s.bodies.values())) if (bb != null) sb.append(new String(bb, StandardCharsets.ISO_8859_1));
            String body = sb.toString();
            check("(n) a closeStream after the ownership check, before the body is sent, delivers no token and ends the loop",
                  !th.isAlive() && !body.contains("gwtok"), "alive=" + th.isAlive() + " n=" + s.n() + " lines=" + s.reqLine + " body=[" + body + "]");
            halt(p); s.close();
        }
        // (o) a closeStream on ANOTHER thread while the body write is in progress must not return until the write is done.
        // Every wait ends on an event, never a fixed time: a stalled thread makes the case slower, never changes its verdict.
        for (final long stall : new long[] {0, 1000}) {
            final String o1 = stall == 0 ? "(o1)" : "(o3a)", o2 = stall == 0 ? "(o2)" : "(o3b)";
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            final Pump p = new Pump();
            p.port = s.ss.getLocalPort();
            p.openIdx = 0;
            final long[] closeReturned = {0}, writeDone = {0};
            final boolean[] held = {false}, heldOff = {false}, timedOut = {false};
            final java.util.concurrent.CountDownLatch closed = new java.util.concurrent.CountDownLatch(1);
            p.beforeWrite = () -> { // on the stream thread, inside the first body write
                held[0] = Thread.holdsLock(p);
                final long me = Thread.currentThread().getId();
                Thread ct = new Thread(() -> {
                    if (stall > 0) try { Thread.sleep(stall); } catch (InterruptedException e) { }
                    p.closeNow();
                    closeReturned[0] = System.nanoTime();
                    closed.countDown();
                }, "closer");
                ct.setDaemon(true);
                ct.start();
                // Hold the write until the closer has returned, or is BLOCKED on the Pump's monitor with this thread as owner.
                final java.lang.management.ThreadMXBean mx = java.lang.management.ManagementFactory.getThreadMXBean();
                final long end = System.nanoTime() + 30_000_000_000L; // hang guard: a recorded FAILURE, never a pass
                while (closed.getCount() != 0) {
                    java.lang.management.ThreadInfo ti = mx.getThreadInfo(ct.getId());
                    if (ti != null && ti.getThreadState() == Thread.State.BLOCKED && ti.getLockOwnerId() == me) { heldOff[0] = true; break; }
                    if (System.nanoTime() - end > 0) { timedOut[0] = true; break; }
                    try { Thread.sleep(2); } catch (InterruptedException e) { } // the broken code's closeStream interrupts this thread
                }
                writeDone[0] = System.nanoTime();
            };
            final Map<String, Pump.Reg> byGw = ours();
            final List<String> tokens = new ArrayList<>(byGw.keySet());
            final Thread th = new Thread(() -> p.runLoop(tokens, byGw), "push-sse");
            th.setDaemon(true);
            p.streamThread = th;
            th.start();
            closed.await(30, java.util.concurrent.TimeUnit.SECONDS);
            th.join(30_000);
            check(o1 + " the body write runs with the Pump's monitor held (closer stall " + stall + " ms)",
                  held[0], "Thread.holdsLock(p) was false inside the write");
            check(o2 + " a concurrent closeStream is held at the monitor and returns only after the body write (closer stall " + stall + " ms)",
                  heldOff[0] && !timedOut[0] && closeReturned[0] != 0 && closeReturned[0] >= writeDone[0],
                  "heldOff=" + heldOff[0] + " timedOut=" + timedOut[0] + " writeDone=" + writeDone[0] + " closeReturned=" + closeReturned[0]);
            halt(p); s.close();
        }
        final String[] NEW = {"https://gw/ep-new", "gwtok-new", "sec-new-7q"};
        final String GONE = ": keep-alive\n\ngone: gwtok-ours\n\n";
        android.util.Log.msgs.clear();
        { // (p) a gone line for our token: one execute, one mint on the exec thread, one broadcast, regs updated and saved, one reconnect
            Srv s = new Srv((i, o, k) -> silent(o, GONE));
            Map<String, Pump.Reg> byGw = ours();
            Pump p = startRegs(s, byGw, Map.of("apptok", byGw.get("gwtok-ours")), NEW);
            settle(s, p); s.close();
            Pump.Reg nr = p.regs.get("apptok");
            check("(p1) one gone line hands exactly one task to exec", p.exec.calls.get() == 1, "execute calls: " + p.exec.calls.get());
            check("(p2) gatewayRegister runs once, on the exec thread", p.regThreads.equals(Arrays.asList("exec")), "threads: " + p.regThreads);
            check("(p3) one NEW_ENDPOINT broadcast carrying the new endpoint", p.newEps.equals(Arrays.asList("apptok=https://gw/ep-new")), "broadcasts: " + p.newEps);
            check("(p4) regs holds the new gateway token and endpoint for the same package and app token",
                  nr != null && nr.gatewayToken.equals("gwtok-new") && nr.endpoint.equals("https://gw/ep-new") && nr.appPackage.equals("org.example.app"), "reg: " + (nr == null ? "null" : nr.gatewayToken + " " + nr.endpoint + " " + nr.appPackage));
            check("(p5) regs saved once and the stream reconnected once", p.saves.get() == 1 && p.reconnects.get() == 1, "saves=" + p.saves + " reconnects=" + p.reconnects);
        }
        { // (q) a foreign token: nothing
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\ngone: gwtok-other\n\n"));
            Map<String, Pump.Reg> byGw = ours();
            Pump.Reg old = byGw.get("gwtok-ours");
            Pump p = startRegs(s, byGw, Map.of("apptok", old), NEW);
            settle(s, p); s.close();
            check("(q) a gone line for a foreign token does nothing", p.exec.calls.get() == 0 && p.regThreads.isEmpty() && p.newEps.isEmpty()
                  && p.saves.get() == 0 && p.reconnects.get() == 0 && p.regs.get("apptok") == old,
                  "calls=" + p.exec.calls + " threads=" + p.regThreads + " eps=" + p.newEps + " saves=" + p.saves + " reconnects=" + p.reconnects);
        }
        { // (r) two gone lines for one token in one connection: one re-mint
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\ngone: gwtok-ours\n\ngone: gwtok-ours\n\n"));
            Map<String, Pump.Reg> byGw = ours();
            Pump p = startRegs(s, byGw, Map.of("apptok", byGw.get("gwtok-ours")), NEW);
            settle(s, p); s.close();
            check("(r) two gone lines for one token re-mint once", p.exec.calls.get() == 1 && p.regThreads.size() == 1, "calls=" + p.exec.calls + " threads=" + p.regThreads);
        }
        { // (s) the mint fails: regs unchanged, no broadcast, no save, no reconnect
            Srv s = new Srv((i, o, k) -> silent(o, GONE));
            Map<String, Pump.Reg> byGw = ours();
            Pump.Reg old = byGw.get("gwtok-ours");
            Pump p = startRegs(s, byGw, Map.of("apptok", old), null);
            settle(s, p); s.close();
            check("(s) a failed mint leaves regs, broadcast, save and stream alone", p.exec.calls.get() == 1 && p.regThreads.size() == 1 && p.regs.get("apptok") == old
                  && p.newEps.isEmpty() && p.saves.get() == 0 && p.reconnects.get() == 0,
                  "calls=" + p.exec.calls + " threads=" + p.regThreads + " eps=" + p.newEps + " saves=" + p.saves + " reconnects=" + p.reconnects);
        }
        { // (t) a gone line and a data line in one stream: the message still broadcasts once
            final String b64 = java.util.Base64.getEncoder().encodeToString("hi".getBytes(StandardCharsets.UTF_8));
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\ngone: gwtok-ours\n\ndata: {\"token\":\"gwtok-ours\",\"message\":\"" + b64 + "\"}\n\n"));
            Map<String, Pump.Reg> byGw = ours();
            Pump p = startRegs(s, byGw, Map.of("apptok", byGw.get("gwtok-ours")), NEW);
            settle(s, p); s.close();
            check("(t) a data line beside a gone line broadcasts its message exactly once", p.got.equals(Arrays.asList("apptok=hi")) && p.exec.calls.get() == 1, "got=" + p.got + " calls=" + p.exec.calls);
        }
        { // (w) a Reg with a stream secret and one without: the POST body presents the one secret, keyed by its token
            Srv s = new Srv((i, o, k) -> silent(o, ": keep-alive\n\n"));
            Map<String, Pump.Reg> byGw = new LinkedHashMap<>();
            byGw.put("gwtok-a", new Pump.Reg("org.example.app", "apptok", "gwtok-a", "https://gw/ep-a", "sec-a-7q"));
            byGw.put("gwtok-b", new Pump.Reg("org.example.other", "apptok-b", "gwtok-b", "https://gw/ep-b"));
            Pump p = start(s, byGw);
            s.waitFor(1, 3000);
            byte[] bd = s.bodies.get(0) == null ? new byte[0] : s.bodies.get(0);
            String want = "{\"tokens\":[\"gwtok-a\",\"gwtok-b\"],\"secrets\":{\"gwtok-a\":\"sec-a-7q\"}}";
            check("(w) the POST body is exactly " + want, Arrays.equals(bd, want.getBytes(StandardCharsets.UTF_8)), "body: " + new String(bd, StandardCharsets.ISO_8859_1));
            halt(p); s.close();
        }
        { // (x) a gone: re-mint answered with a new secret: regs holds the new registration with that secret
            Srv s = new Srv((i, o, k) -> silent(o, GONE));
            Map<String, Pump.Reg> byGw = ours();
            Pump p = startRegs(s, byGw, Map.of("apptok", byGw.get("gwtok-ours")), NEW);
            settle(s, p); s.close();
            Pump.Reg nr = p.regs.get("apptok");
            check("(x) a re-mint keeps the secret /push/register returned", nr != null && nr.gatewayToken.equals("gwtok-new") && "sec-new-7q".equals(nr.secret),
                  "reg: " + (nr == null ? "null" : nr.gatewayToken + " secret=" + nr.secret));
        }
        { // (u) no recorded log message holds a token, an endpoint or a secret, and the re-mint did log the package
            boolean leak = false; String which = "";
            for (String m : new ArrayList<>(android.util.Log.msgs)) for (String bad : new String[]{"gwtok-ours", "gwtok-new", "apptok", "https://gw/ep", "sec-new-7q", "sec-a-7q"}) if (m.contains(bad)) { leak = true; which = m; }
            boolean pkg = false; for (String m : android.util.Log.msgs) if (m.contains("org.example.app")) pkg = true;
            check("(u) no log message holds a token, an endpoint or a secret, and the package is named", !leak && pkg, "leak=" + leak + " in [" + which + "] pkg=" + pkg + " all=" + android.util.Log.msgs);
        }
        { // (v) a Reg replaced in regs before the task runs: no mint
            Srv s = new Srv((i, o, k) -> silent(o, GONE));
            Map<String, Pump.Reg> byGw = ours();
            Pump.Reg repl = new Pump.Reg("org.example.app", "apptok", "gwtok-repl", "https://gw/ep-repl");
            Pump p = startRegs(s, byGw, Map.of("apptok", repl), NEW);
            settle(s, p); s.close();
            check("(v) a registration replaced before the task runs is not re-minted", p.exec.calls.get() == 1 && p.regThreads.isEmpty() && p.newEps.isEmpty()
                  && p.saves.get() == 0 && p.regs.get("apptok") == repl, "calls=" + p.exec.calls + " threads=" + p.regThreads + " eps=" + p.newEps + " saves=" + p.saves);
        }
        System.out.println("passed " + pass + ", failed " + fail);
        Runtime.getRuntime().halt(fail == 0 ? 0 : 1);
    }
}
J
  } >"$d/Harness.java"
  "$JAVAC" -J-XX:-UsePerfData -encoding UTF-8 -d "$d/out" "$d"/android/util/*.java "$d"/org/json/*.java "$d/Harness.java" >"$d/compile.log" 2>&1 \
    || { cat "$d/compile.log" >&2; return 3; }
  "$JAVA" -XX:-UsePerfData -Djava.io.tmpdir="$W" -cp "$d/out" Harness
}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
run_one "$SRC"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (exit $rc: 1 a case, 2 cannot run / extraction failed, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutants (each MUST be convicted by a case) =="
  mutant(){ # mutant <label> <sed script on the lifted code>
    local r; run_one "$SRC" "$2" >/dev/null 2>&1; r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTANT BROKEN (exit $r, not a case): $1" ;;
    esac
  }
  mutant "the read timeout back to 0 at the call"            's/setReadTimeout(STREAM_READ_TIMEOUT_MS)/setReadTimeout(0)/'
  mutant "the timeout constant set to 0"                     's/STREAM_READ_TIMEOUT_MS = 600/STREAM_READ_TIMEOUT_MS = 0/'
  mutant "the foreign-token check removed"                   's/if (r == null) return;//'
  mutant "the backoff reset after a healthy connect removed" '/backoff = 2000; \/\/ healthy/d'
  mutant "fall back to GET on a 400 as well"                 's/code == 404 || code == 405/code == 404 || code == 405 || code == 400/'
  mutant "fall back on 405 only (404 dropped)"               's/code == 404 || code == 405/code == 405/'
  mutant "the tokens appended to the POST URL"               's|gatewayBase() + "/push/stream")|gatewayBase() + "/push/stream?tokens=" + tokens.get(0))|'
  mutant "streamGetOnly never set"                           's/streamGetOnly = true;//'
  mutant "the escaper's backslash case dropped"              '/case .\\\\.: sb.append/d'
  mutant "the handoff guards removed (an uncancelable fallback GET)" '/^ \{24\}if (stopping || self != streamThread) return/d'
  mutant "the post-connect check removed (GET)"            '/^ \{24\}if (streamConn != c) return;/d'
  mutant "the post-open check removed (POST)"              '/^ \{28\}if (streamConn != c) return;/d'
  mutant "the body written outside the ownership monitor"   's/^ \{28\}os.write(body);/ } os.write(body); synchronized (this) {/'
  mutant "the GET fallback taken after the backoff sleep"    's/^ *c = null;$/throw new Exception("late");/'
  mutant "seen dropped (every gone line re-mints)"           's/if (!seen.add(gwToken)) return;/seen.add(gwToken);/'
  mutant "the re-mint run on the stream thread"              's/exec.execute(() -> remint(r));/remint(r);/'
  mutant "the changed-meanwhile guard dropped"               '/if (regs.get(old.appToken) != old) return;/d'
  mutant "the gateway token logged"                          's/Log.i(TAG, "re-minted " + old.appPackage/Log.i(TAG, "re-minted " + nr.gatewayToken + " " + old.appPackage/'
  mutant "the gone: dispatch line dropped"                   '/line.startsWith("gone: ")/d'
  mutant "S4: remint passes null for the new secret"         's/old.appToken, ep\[1\], ep\[0\], ep\[2\])/old.appToken, ep[1], ep[0], null)/'
  mutant "streamLoop sends no secrets"                       's/streamBody(tokens, byGw)/streamBody(tokens, new LinkedHashMap<String, Reg>())/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] && exit 0
# cannot-run (2) and no-compile (3) are not a failed case: keep the status at the suite boundary
case "$rc" in 2|3) exit "$rc" ;; esac
exit 1
