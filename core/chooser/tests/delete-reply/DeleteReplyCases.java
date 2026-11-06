// DeleteReplyCases -- NWP-20261014-30: what the Delete screen says for each daemon reply (#140).
public final class DeleteReplyCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL  " + what); }
    }

    public static void main(String[] a) {
        check(Lifted.deleteSucceeded("OK"), "OK succeeds");
        check(Lifted.deleteSucceeded("OK GONE"), "OK GONE succeeds");
        for (String r : new String[] {"BUSY", "BUSY x", "ERR-STORE", "NOTFOUND", "", "BLANK", "ERR-X"}) {
            check(!Lifted.deleteSucceeded(r), "'" + r + "' is not a success");
        }

        String busy = Lifted.deleteFailCopy("BUSY");
        check(busy.contains("busy"), "BUSY -> busy copy");
        check(busy.equals(Lifted.deleteFailCopy("BUSY x")), "'BUSY x' -> the same busy copy");

        String store = Lifted.deleteFailCopy("ERR-STORE");
        check(store.contains("reach your storage"), "ERR-STORE -> storage copy");
        check(!store.equals(Lifted.deleteFailCopy("NOTFOUND")), "ERR-STORE is not the NOTFOUND copy");

        String none = Lifted.deleteFailCopy("");
        check(none.contains("may or may not have gone through"), "'' -> the may-or-may-not copy");
        check(!none.contains("nothing was deleted"), "'' never claims nothing was deleted");

        String generic = Lifted.deleteFailCopy("ERR-X");
        check(generic.equals(Lifted.deleteFailCopy("BLANK")), "BLANK and ERR-X share the generic copy");
        check(generic.contains("couldn't delete"), "generic copy says couldn't delete");

        String[] all = {"BUSY", "BUSY x", "ERR-STORE", "NOTFOUND", "", "BLANK", "ERR-X"};
        for (String r : all) {
            String c = Lifted.deleteFailCopy(r);
            check(c.contains("passphrase") == r.equals("NOTFOUND"), "only NOTFOUND mentions the passphrase ('" + r + "')");
            if (!r.isEmpty()) check(c.contains("nothing was deleted"), "'" + r + "' says nothing was deleted");
        }

        // NWP-20261028-03: the store is skipped only when there is no default network AND no non-VPN INTERNET network.
        check(!Lifted.deleteSkipsStore(true, true), "a default network and another -> send");
        check(!Lifted.deleteSkipsStore(true, false), "a default network only -> send");
        check(!Lifted.deleteSkipsStore(false, true), "no default network but a non-VPN internet one (lockdown VPN down) -> send");
        check(Lifted.deleteSkipsStore(false, false), "no network at all -> skip the store");

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("delete-reply: all cases passed");
    }
}
