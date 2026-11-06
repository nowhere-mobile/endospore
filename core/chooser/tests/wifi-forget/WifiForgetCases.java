package com.nowhere.chooser;

/** WifiForget.run over a recording fake: the verdict, and which calls were made. */
public final class WifiForgetCases {
    static int fails = 0;

    static final class Fake implements WifiForget.Ops {
        final StringBuilder calls = new StringBuilder();
        int netId = 7;
        boolean removeResult = true;
        RuntimeException connectedThrows, removeThrows, disconnectThrows;

        public int connectedNetId() {
            calls.append("connectedNetId;");
            if (connectedThrows != null) throw connectedThrows;
            return netId;
        }
        public boolean remove(int id) {
            calls.append("remove(").append(id).append(");");
            if (removeThrows != null) throw removeThrows;
            return removeResult;
        }
        public void disconnect() {
            calls.append("disconnect;");
            if (disconnectThrows != null) throw disconnectThrows;
        }
    }

    static void eq(String what, String got, String want) {
        if (!want.equals(got)) { fails++; System.out.println("--- FAIL " + what + ": got \"" + got + "\" want \"" + want + "\""); }
    }

    public static void main(String[] a) {
        Fake f = new Fake();
        eq("(a) verdict", WifiForget.run(f), "OK");
        eq("(a) calls", f.calls.toString(), "connectedNetId;remove(7);disconnect;");

        f = new Fake(); f.removeResult = false;
        eq("(b) verdict", WifiForget.run(f), "ERR refused");
        eq("(b) calls", f.calls.toString(), "connectedNetId;remove(7);");

        f = new Fake(); f.netId = -1;
        eq("(c) verdict", WifiForget.run(f), "ERR not connected");
        eq("(c) calls", f.calls.toString(), "connectedNetId;");

        f = new Fake(); f.disconnectThrows = new IllegalStateException("radio busy");
        eq("(d) verdict", WifiForget.run(f), "OK");
        eq("(d) calls", f.calls.toString(), "connectedNetId;remove(7);disconnect;");

        f = new Fake(); f.removeThrows = new SecurityException("not owner");
        eq("(e) verdict", WifiForget.run(f), "ERR not owner");
        eq("(e) calls", f.calls.toString(), "connectedNetId;remove(7);");
        f = new Fake(); f.removeThrows = new IllegalStateException();
        eq("(e) null message", WifiForget.run(f), "ERR failed");

        f = new Fake(); f.connectedThrows = new IllegalStateException("no wifi");
        eq("(f) verdict", WifiForget.run(f), "ERR no wifi");
        eq("(f) calls", f.calls.toString(), "connectedNetId;");

        if (fails > 0) { System.out.println("FAILED " + fails); System.exit(1); }
        System.out.println("ok: cases a-f");
    }
}
