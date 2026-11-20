// Cases for StorageFolders (NWP-20261125-09; F1-F3 NWP-20261210-22). Run by run.sh; prints "FAIL <case>" per
// failure and exits 1.
public class StorageFoldersCases {
    static int fails = 0;

    static void ok(String name, boolean cond, String detail) {
        if (cond) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + ": " + detail); fails++; }
    }

    public static void main(String[] a) {
        String t = StorageFolders.title("");
        ok("c1 title(\"\") names the files outside every folder", "Files outside folders".equals(t), "got " + t);
        t = StorageFolders.title(null);
        ok("c1 title(null) names the files outside every folder", "Files outside folders".equals(t), "got " + t);
        t = StorageFolders.title("Download");
        ok("c2 title(\"Download\") is the folder's name", "Download".equals(t), "got " + t);

        String l = StorageFolders.line("1 MB", "373 MB", true);
        ok("c3 a measured line leads with the plan", "373 MB of your plan · 1 MB on this phone".equals(l), "got " + l);
        l = StorageFolders.line("1 MB", "373 MB", false);
        ok("c4 a line not measured keeps today's words", "1 MB on this phone · always comes with you".equals(l),
                "got " + l);

        ok("c5 useFolderRows(0) is false", !StorageFolders.useFolderRows(0), "got true");
        ok("c6 useFolderRows(1) is true", StorageFolders.useFolderRows(1), "got false");

        // NWP-20261210-22 (h51 #4): a named folder row with store figures offers Free on this phone.
        ok("F1 freeOffer(\"\") is false: the outside row is never offered", !StorageFolders.freeOffer("", 5, true),
                "got true");
        ok("F1 freeOffer(null) is false", !StorageFolders.freeOffer(null, 5, true), "got true");
        ok("F1 freeOffer not measured is false", !StorageFolders.freeOffer("Download", 5, false), "got true");
        ok("F1 freeOffer with store 0 is false", !StorageFolders.freeOffer("Download", 0, true), "got true");
        ok("F1 freeOffer(\"Download\", 5, measured) is true", StorageFolders.freeOffer("Download", 5, true),
                "got false");

        long n = StorageFolders.freedBytes("OK 5");
        ok("F2 freedBytes(\"OK 5\") is 5", n == 5, "got " + n);
        n = StorageFolders.freedBytes("OK 0");
        ok("F2 freedBytes(\"OK 0\") is 0", n == 0, "got " + n);
        for (String r : new String[] {"OK x", "OK -1", "OK", "OK 5 6", "OK 99999999999999999999", "ERR-HEAD", null}) {
            n = StorageFolders.freedBytes(r);
            ok("F2 freedBytes(" + r + ") is -1", n == -1, "got " + n);
        }

        String m = StorageFolders.freeMessage("OK 5", "5 B");
        ok("F3 freeMessage(OK 5) holds the FREED words and the size",
                "Freed 5 B of streamed copies".equals(m), "got " + m);
        m = StorageFolders.freeMessage("OK 0", "0 B");
        ok("F3 freeMessage(OK 0) is NOTHING", StorageFolders.NOTHING.equals(m)
                && "Nothing streamed from this folder is on the phone".equals(m), "got " + m);
        m = StorageFolders.freeMessage("NONE", "");
        ok("F3 freeMessage(NONE) is NO_SESSION", StorageFolders.NO_SESSION.equals(m)
                && "No active session".equals(m), "got " + m);
        for (String r : new String[] {"LOCAL", "ERR-FOLDER", "ERR-HEAD", "ERR-NOKEYS", "", null}) {
            m = StorageFolders.freeMessage(r, "");
            ok("F3 freeMessage(" + r + ") is FAILED", StorageFolders.FAILED.equals(m)
                    && "Couldn't free space \u2014 try again".equals(m), "got " + m);
        }

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
    }
}
