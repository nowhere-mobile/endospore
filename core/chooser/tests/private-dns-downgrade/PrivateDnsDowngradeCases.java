package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261122-07: the cases of test-private-dns-downgrade-java.sh, compiled with PrivateDnsDowngrade.java alone.
 * NWP-20261127-07: the surface (gate, session uid, none) and the session sequences S1-S8; R1, a retained dialog after a
 * restart of user 0's process (RF-001).
 */
public class PrivateDnsDowngradeCases {
    static int fails = 0;

    static void ok(String what, boolean cond, String got) {
        if (cond) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got);
    }

    static void eq(String what, Object got, Object want) {
        ok(what, want == null ? got == null : want.equals(got), String.valueOf(got) + ", want " + want);
    }

    /** A network handle: equal by id, like android.net.Network (a fresh parcelled object per callback). */
    static final class Net {
        final int id;
        Net(int id) { this.id = id; }
        @Override public boolean equals(Object o) { return o instanceof Net && ((Net) o).id == id; }
        @Override public int hashCode() { return id; }
    }

    /** The settings and the marker. A restart is a fresh FakeIo over the same marker and setting. */
    static final class FakeIo implements PrivateDnsDowngrade.Io {
        final String[] mode;
        final boolean[] marker;
        final List<String> ops = new ArrayList<>();
        boolean markFails, setFails;

        FakeIo(String[] mode, boolean[] marker) { this.mode = mode; this.marker = marker; }
        FakeIo(String m, boolean marked) { this(new String[] { m }, new boolean[] { marked }); }

        @Override public String mode() { return mode[0]; }
        @Override public boolean setMode(String m) {
            ops.add("mode=" + m);
            if (setFails) return false;
            mode[0] = m;
            return true;
        }
        @Override public boolean marked() { return marker[0]; }
        @Override public boolean mark() {
            ops.add("mark");
            if (markFails) return false;
            marker[0] = true;
            return true;
        }
        @Override public boolean unmark() {
            ops.add("unmark");
            marker[0] = false;
            return true;
        }
    }

    /** The prompt's surfaces: records show(token, surface) and dismiss. */
    static final class FakeUi implements PrivateDnsDowngrade.Ui {
        final List<String> ops = new ArrayList<>();
        long lastShown;
        int lastSurface = Integer.MIN_VALUE;

        @Override public boolean show(long token, int surface) {
            ops.add("show");
            lastShown = token;
            lastSurface = surface;
            return true;
        }
        @Override public void dismiss() { ops.add("dismiss"); }
    }

    /** A gate in front on a blocked network A, its dialog up: the start of every RF-001 sequence. */
    static PrivateDnsDowngrade.Gate askedOnA(FakeIo io, FakeUi ui, Net a) {
        PrivateDnsDowngrade.Gate g = new PrivateDnsDowngrade.Gate(io, ui);
        g.onAvailable(a);
        g.onSurface(PrivateDnsDowngrade.SURFACE_GATE);
        g.onBroken(a, true);
        return g;
    }

    /** A roamed user uid in front on a blocked network A, the notification posted there: the start of S1-S6. */
    static PrivateDnsDowngrade.Gate askedInSession(FakeIo io, FakeUi ui, Net a, int uid) {
        PrivateDnsDowngrade.Gate g = new PrivateDnsDowngrade.Gate(io, ui);
        g.onAvailable(a);
        g.onSurface(uid);
        g.onBroken(a, true);
        return g;
    }

    public static void main(String[] a) throws Exception {
        // 1. blocked: only hostname mode with the signal
        eq("blocked hostname + broken", PrivateDnsDowngrade.blocked("hostname", true), true);
        eq("not blocked hostname, not broken", PrivateDnsDowngrade.blocked("hostname", false), false);
        eq("not blocked off + broken", PrivateDnsDowngrade.blocked("off", true), false);
        eq("not blocked unset + broken", PrivateDnsDowngrade.blocked(null, true), false);
        eq("not blocked another mode + broken", PrivateDnsDowngrade.blocked("automatic", true), false);

        // 2. prompt
        Net net = new Net(100), sameNet = new Net(100), other = new Net(101);
        final int GATE = PrivateDnsDowngrade.SURFACE_GATE, NONE = PrivateDnsDowngrade.SURFACE_NONE;
        eq("prompt: blocked, gate in front, a network", PrivateDnsDowngrade.prompt(true, GATE, net, null), true);
        eq("no prompt: gate not in front", PrivateDnsDowngrade.prompt(true, NONE, net, null), false);
        eq("no prompt: not blocked", PrivateDnsDowngrade.prompt(false, GATE, net, null), false);
        eq("no prompt: no network", PrivateDnsDowngrade.prompt(true, GATE, null, null), false);
        eq("no prompt: the declined network", PrivateDnsDowngrade.prompt(true, GATE, net, net), false);
        eq("no prompt: the declined network, a fresh equal object", PrivateDnsDowngrade.prompt(true, GATE, sameNet, net), false);
        eq("prompt again on a new network", PrivateDnsDowngrade.prompt(true, GATE, other, net), true);
        eq("prompt: a session surface prompts", PrivateDnsDowngrade.prompt(true, 7, net, null), true);
        eq("no prompt: a session surface, the declined network", PrivateDnsDowngrade.prompt(true, 7, net, net), false);

        // 3. downgrade: the marker, then off
        FakeIo io = new FakeIo("hostname", false);
        eq("downgrade returns true", PrivateDnsDowngrade.downgrade(io), true);
        eq("downgrade order: the marker, then off", io.ops, Arrays.asList("mark", "mode=off"));
        eq("downgrade value", io.mode[0], "off");
        eq("downgrade leaves the marker", io.marker[0], true);

        // 4. the marker cannot be written: no mode write
        io = new FakeIo("hostname", false);
        io.markFails = true;
        eq("downgrade without a marker returns false", PrivateDnsDowngrade.downgrade(io), false);
        eq("downgrade without a marker writes no mode", io.ops, Arrays.asList("mark"));
        eq("downgrade without a marker keeps hostname", io.mode[0], "hostname");

        // 5. the mode is no longer strict: nothing at all
        io = new FakeIo("off", false);
        eq("downgrade from off returns false", PrivateDnsDowngrade.downgrade(io), false);
        eq("downgrade from off writes nothing", io.ops, new ArrayList<String>());

        // 6. restore with the marker: hostname, then the marker removed
        io = new FakeIo("off", true);
        eq("restore with the marker returns true", PrivateDnsDowngrade.restoreIfMarked(io), true);
        eq("restore order: hostname, then unmark", io.ops, Arrays.asList("mode=hostname", "unmark"));
        eq("restore value", io.mode[0], "hostname");
        eq("restore removes the marker", io.marker[0], false);

        // 7. restore without the marker: nothing, the owner's own setting survives
        io = new FakeIo("off", false);
        eq("restore without the marker returns false", PrivateDnsDowngrade.restoreIfMarked(io), false);
        eq("restore without the marker writes nothing", io.ops, new ArrayList<String>());
        eq("restore without the marker keeps the owner's off", io.mode[0], "off");

        // 8. the hostname write fails: the marker stays for the next start or network change
        io = new FakeIo("off", true);
        io.setFails = true;
        eq("restore with a failed write returns false", PrivateDnsDowngrade.restoreIfMarked(io), false);
        eq("restore with a failed write keeps the marker", io.marker[0], true);
        eq("restore with a failed write does not unmark", io.ops, Arrays.asList("mode=hostname"));

        // 9. a downgrade, then a restart: a fresh io over the same marker restores
        String[] setting = { "hostname" };
        boolean[] marker = { false };
        PrivateDnsDowngrade.downgrade(new FakeIo(setting, marker));
        eq("after the downgrade the setting is off", setting[0], "off");
        FakeIo restarted = new FakeIo(setting, marker);
        eq("the restart restores", PrivateDnsDowngrade.restoreIfMarked(restarted), true);
        eq("after the restart the setting is hostname", setting[0], "hostname");
        eq("after the restart the marker is gone", marker[0], false);
        FakeIo again = new FakeIo(setting, marker);
        PrivateDnsDowngrade.restoreIfMarked(again);
        eq("a second restart writes nothing", again.ops, new ArrayList<String>());

        // 11. RF-001: the dialog belongs to one default network
        Net netA = new Net(200), netB = new Net(201), netA2 = new Net(200);
        FakeIo gio = new FakeIo("hostname", false);
        FakeUi ui = new FakeUi();
        PrivateDnsDowngrade.Gate g = askedOnA(gio, ui, netA);
        eq("seq A blocked, gate in front: the dialog shows", ui.ops, Arrays.asList("show"));
        long tokA = ui.lastShown;
        g.onBroken(netA2, true);
        eq("seq the same network again: no second dialog", ui.ops, Arrays.asList("show"));
        eq("seq a new default network B: the onAvailable is new", g.onAvailable(netB), true);
        eq("seq a new default network B: A's dialog is dismissed", ui.ops, Arrays.asList("show", "dismiss"));
        eq("seq Continue on A's old dialog after B came: no downgrade", g.onContinue(tokA), false);
        eq("seq Continue on A's old dialog after B came: nothing written", gio.ops, new ArrayList<String>());
        eq("seq ... strict mode stays on B", gio.mode[0], "hostname");

        // 11b. B is blocked too: B's own dialog shows; A's stale button still writes nothing
        g.onBroken(netB, true);
        eq("seq B blocked: B's own dialog shows", ui.ops, Arrays.asList("show", "dismiss", "show"));
        long tokB = ui.lastShown;
        eq("seq B's dialog has a new token", tokB != tokA, true);
        eq("seq A's stale Continue while B's dialog is up: no downgrade", g.onContinue(tokA), false);
        eq("seq A's stale Continue while B's dialog is up: nothing written", gio.ops, new ArrayList<String>());
        g.onStay(tokA);
        eq("seq Continue on B's own dialog downgrades", g.onContinue(tokB), true);
        eq("seq ... marker, then off", gio.ops, Arrays.asList("mark", "mode=off"));

        // 11c. the broken signal clears while the dialog is up: it closes, and its Continue writes nothing
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedOnA(gio, ui, netA);
        tokA = ui.lastShown;
        g.onBroken(netA, false);
        eq("seq the signal clears: the dialog is dismissed", ui.ops, Arrays.asList("show", "dismiss"));
        eq("seq Continue after the signal cleared: no downgrade", g.onContinue(tokA), false);
        eq("seq ... nothing written", gio.ops, new ArrayList<String>());

        // 11d. A is lost: the dialog closes, and its Continue writes nothing
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedOnA(gio, ui, netA);
        tokA = ui.lastShown;
        g.onLost(netA2);
        eq("seq A lost: the dialog is dismissed", ui.ops, Arrays.asList("show", "dismiss"));
        eq("seq Continue after A was lost: no downgrade", g.onContinue(tokA), false);
        eq("seq ... nothing written", gio.ops, new ArrayList<String>());

        // 11e. a lost network that is not the default one changes nothing
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedOnA(gio, ui, netA);
        tokA = ui.lastShown;
        g.onLost(netB);
        eq("seq another network lost: the dialog stays", ui.ops, Arrays.asList("show"));
        eq("seq ... its Continue still downgrades", g.onContinue(tokA), true);

        // 11f. the gate leaves the front: the dialog closes; back in front it asks again with a new token
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedOnA(gio, ui, netA);
        tokA = ui.lastShown;
        g.onSurface(PrivateDnsDowngrade.SURFACE_NONE);
        eq("seq the gate leaves the front: the dialog is dismissed", ui.ops, Arrays.asList("show", "dismiss"));
        g.onDismissed(tokA);
        g.onSurface(PrivateDnsDowngrade.SURFACE_GATE);
        eq("seq the gate is back: it asks again", ui.ops, Arrays.asList("show", "dismiss", "show"));
        eq("seq ... the old dialog's Continue writes nothing", g.onContinue(tokA), false);
        eq("seq ... nothing written", gio.ops, new ArrayList<String>());

        // 11g. Stay private: not asked again on that network (a fresh equal object), asked on a new one
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedOnA(gio, ui, netA);
        g.onStay(ui.lastShown);
        g.onBroken(netA2, true);
        g.onSurface(PrivateDnsDowngrade.SURFACE_NONE);
        g.onSurface(PrivateDnsDowngrade.SURFACE_GATE);
        eq("seq Stay private: not asked again on A", ui.ops, Arrays.asList("show"));
        g.onAvailable(netB);
        g.onBroken(netB, true);
        eq("seq Stay private on A: asked on B", ui.ops, Arrays.asList("show", "show"));
        eq("seq ... nothing written", gio.ops, new ArrayList<String>());

        // 11h. the dialog could not show: the next event tries again
        gio = new FakeIo("hostname", false);
        final int[] shows = { 0 };
        PrivateDnsDowngrade.Ui failing = new PrivateDnsDowngrade.Ui() {
            @Override public boolean show(long token, int surface) { return ++shows[0] > 1; }
            @Override public void dismiss() {}
        };
        g = new PrivateDnsDowngrade.Gate(gio, failing);
        g.onAvailable(netA);
        g.onSurface(PrivateDnsDowngrade.SURFACE_GATE);
        g.onBroken(netA, true);
        g.onBroken(netA, true);
        eq("seq a failed show is retried at the next event", shows[0], 2);

        // 12. surface(): the resumed gate wins; else a roamed current user; else NONE
        eq("surface: gate resumed, user 0 current", PrivateDnsDowngrade.surface(true, 0), GATE);
        eq("surface: gate resumed wins over a session user", PrivateDnsDowngrade.surface(true, 10), GATE);
        eq("surface: a roamed user in front", PrivateDnsDowngrade.surface(false, 10), 10);
        eq("surface: user 0 current, gate not resumed", PrivateDnsDowngrade.surface(false, 0), NONE);
        eq("surface: the current user unread", PrivateDnsDowngrade.surface(false, -1), NONE);

        // NWP-20261127-07: the session half (h50 #4 A1). uid 10 and 11 are two roamed users.
        final int UA = 10, UB = 11;

        // S1 blocked with a session in front: the prompt goes to that session
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedInSession(gio, ui, netA, UA);
        eq("S1 blocked, a session in front: shown", ui.ops, Arrays.asList("show"));
        eq("S1 ... on the session's surface", ui.lastSurface, UA);
        long tokS = ui.lastShown;

        // S2 session -> gate: the notification is dismissed and the gate dialog shows with a new token
        g.onSurface(GATE);
        eq("S2 session -> gate: dismissed, then shown again", ui.ops, Arrays.asList("show", "dismiss", "show"));
        eq("S2 ... on the gate", ui.lastSurface, GATE);
        long tokG = ui.lastShown;
        eq("S2 ... with a new token", tokG != tokS && tokG != 0, true);

        // S3 the old (session) token after S2: Continue and Stay do nothing; the gate's own prompt still stands
        eq("S3 the old token's Continue: no downgrade", g.onContinue(tokS), false);
        eq("S3 ... nothing written", gio.ops, new ArrayList<String>());
        eq("S3 ... strict mode stays", gio.mode[0], "hostname");
        g.onStay(tokS);
        eq("S3 the old token's Stay did not decline: the gate's Continue downgrades", g.onContinue(tokG), true);
        eq("S3 ... marker, then off", gio.ops, Arrays.asList("mark", "mode=off"));

        // S4 Continue from the session token: the marker, then off; the next network restores hostname
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedInSession(gio, ui, netA, UA);
        eq("S4 Continue from the session downgrades", g.onContinue(ui.lastShown), true);
        eq("S4 ... marker, then off", gio.ops, Arrays.asList("mark", "mode=off"));
        eq("S4 ... the next network is new", g.onAvailable(netB), true);
        eq("S4 ... and the restore runs", PrivateDnsDowngrade.restoreIfMarked(gio), true);
        eq("S4 ... hostname is back", gio.mode[0], "hostname");
        eq("S4 ... the marker is gone", gio.marker[0], false);

        // S5 Stay private from the session: not asked again on that network, asked on a new one
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedInSession(gio, ui, netA, UA);
        g.onStay(ui.lastShown);
        g.onBroken(netA2, true);
        g.onSurface(GATE);
        g.onSurface(UA);
        eq("S5 Stay private in the session: not asked again on A", ui.ops, Arrays.asList("show"));
        g.onAvailable(netB);
        g.onBroken(netB, true);
        eq("S5 ... asked on B", ui.ops, Arrays.asList("show", "show"));
        eq("S5 ... in the session", ui.lastSurface, UA);
        eq("S5 ... nothing written", gio.ops, new ArrayList<String>());

        // S6 session A -> session B: the prompt moves to B with a new token; A's token does nothing
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = askedInSession(gio, ui, netA, UA);
        long tokUA = ui.lastShown;
        g.onSurface(UB);
        eq("S6 session A -> B: dismissed, then shown again", ui.ops, Arrays.asList("show", "dismiss", "show"));
        eq("S6 ... in B", ui.lastSurface, UB);
        eq("S6 ... with a new token", ui.lastShown != tokUA, true);
        eq("S6 A's token's Continue: no downgrade", g.onContinue(tokUA), false);
        eq("S6 ... nothing written", gio.ops, new ArrayList<String>());

        // S7 NONE shows nothing, and a prompt open at the gate closes when the surface goes to NONE
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = new PrivateDnsDowngrade.Gate(gio, ui);
        g.onAvailable(netA);
        g.onSurface(NONE);
        g.onBroken(netA, true);
        eq("S7 NONE: nothing shown", ui.ops, new ArrayList<String>());
        g.onSurface(GATE);
        g.onSurface(NONE);
        eq("S7 gate -> NONE: dismissed, nothing shown after", ui.ops, Arrays.asList("show", "dismiss"));

        // S8 a Gate first fed a session (a process born mid-session, no switch after it), then broken
        gio = new FakeIo("hostname", false);
        ui = new FakeUi();
        g = new PrivateDnsDowngrade.Gate(gio, ui);
        g.onSurface(UA);
        g.onAvailable(netA);
        g.onBroken(netA, true);
        eq("S8 born mid-session, then blocked: shown", ui.ops, Arrays.asList("show"));
        eq("S8 ... in the session", ui.lastSurface, UA);

        // R1 RF-001: a session dialog outlives user 0's process. A Gate born after the restart, on a new blocked network,
        // must not accept the retained dialog's token; its own prompt still works.
        String[] rSetting = { "hostname" };
        boolean[] rMarker = { false };
        FakeUi rUi = new FakeUi();
        askedInSession(new FakeIo(rSetting, rMarker), rUi, netA, UA);
        long retained = rUi.lastShown;
        FakeIo rIo = new FakeIo(rSetting, rMarker);
        PrivateDnsDowngrade.restoreIfMarked(rIo);
        FakeUi rUi2 = new FakeUi();
        PrivateDnsDowngrade.Gate rg = askedInSession(rIo, rUi2, netB, UA);
        eq("R1 the restarted Gate asks on B", rUi2.ops, Arrays.asList("show"));
        eq("R1 ... with a token the old Gate never gave", rUi2.lastShown != retained && rUi2.lastShown != 0, true);
        eq("R1 the retained dialog's Continue: no downgrade", rg.onContinue(retained), false);
        eq("R1 ... nothing written", rIo.ops, new ArrayList<String>());
        eq("R1 ... strict mode stays", rSetting[0], "hostname");
        rg.onStay(retained);
        eq("R1 the new prompt's Continue still downgrades", rg.onContinue(rUi2.lastShown), true);
        eq("R1 ... marker, then off", rIo.ops, Arrays.asList("mark", "mode=off"));

        // 10. the words, verbatim from h49 #2 (the suite extracted them from the doc)
        List<String> e = Files.readAllLines(Paths.get(a[0]), StandardCharsets.UTF_8);
        eq("title", PrivateDnsDowngrade.TITLE, e.get(0));
        eq("body", PrivateDnsDowngrade.BODY, e.get(1));
        eq("continue button", PrivateDnsDowngrade.CONTINUE, e.get(2));
        eq("stay button", PrivateDnsDowngrade.STAY, e.get(3));
        eq("MODE_OFF", PrivateDnsDowngrade.MODE_OFF, "off");
        eq("MODE_STRICT", PrivateDnsDowngrade.MODE_STRICT, "hostname");

        System.exit(fails == 0 ? 0 : 1);
    }
}
