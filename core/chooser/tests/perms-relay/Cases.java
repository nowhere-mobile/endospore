// NWP-20261112-10: PermsRelayGate's decisions, compiled with the real source and EXECUTED. run.sh prepends the package
// line so these reach the package-private class.
public final class Cases {
    private static int failed = 0;

    private static void expect(String name, boolean want, boolean got) {
        if (want == got) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + " (want " + want + ", got " + got + ")"); failed++; }
    }

    public static void main(String[] a) {
        System.out.println("== armOn: armed only on an OK GRANT-PERMS reply");
        expect("armOn(\"OK\") -> armed", true, PermsRelayGate.armOn("OK"));
        expect("armOn(\"OK x\") -> armed", true, PermsRelayGate.armOn("OK x"));
        expect("armOn(\"ERR-x\") -> not armed", false, PermsRelayGate.armOn("ERR-x"));
        expect("armOn(\"\") -> not armed", false, PermsRelayGate.armOn(""));
        expect("armOn(null) -> not armed", false, PermsRelayGate.armOn(null));
        System.out.println("== relevant: only a change of the armed user's own uid");
        expect("relevant(10*100000+10123, 10) -> relevant", true, PermsRelayGate.relevant(10 * 100000 + 10123, 10));
        expect("relevant(10123, 10) (user 0) -> ignored", false, PermsRelayGate.relevant(10123, 10));
        expect("relevant(x, -1) (disarmed) -> ignored", false, PermsRelayGate.relevant(10 * 100000 + 10123, -1));
        System.out.println("== mayRelay: the armed session, current and unlocked");
        expect("mayRelay(10,10,true) -> relay", true, PermsRelayGate.mayRelay(10, 10, true));
        expect("mayRelay(10,10,false) (locked) -> wait", false, PermsRelayGate.mayRelay(10, 10, false));
        expect("mayRelay(11,10,true) (another user current) -> wait", false, PermsRelayGate.mayRelay(11, 10, true));
        expect("mayRelay(0,0,true) (the gate) -> wait", false, PermsRelayGate.mayRelay(0, 0, true));
        System.out.println("== QUIET_MS: a 2 s quiet spell");
        expect("QUIET_MS == 2000", true, PermsRelayGate.QUIET_MS == 2000);
        if (failed > 0) { System.out.println("FAILED: " + failed + " case(s)"); System.exit(1); }
        System.out.println("all PermsRelayGate cases pass");
    }
}
