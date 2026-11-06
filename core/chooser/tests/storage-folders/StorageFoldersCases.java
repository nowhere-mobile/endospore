// Cases for StorageFolders (NWP-20261125-09). Run by run.sh; prints "FAIL <case>" per failure and exits 1.
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

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
    }
}
