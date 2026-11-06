import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/** NWP-20261104-16 (Q054): which recorded Doze names capture keeps once their app is not installed. args[0] = work dir. */
public final class DozeAbsentCases {
    static int fails = 0;

    static void check(String name, boolean ok) {
        if (!ok) { fails++; System.out.println("  FAIL  " + name); } else System.out.println("  ok    " + name);
    }

    static Set<String> set(String... s) { return new TreeSet<>(Arrays.asList(s)); }

    static void write(File f, String s) throws Exception { Files.write(f.toPath(), s.getBytes(StandardCharsets.UTF_8)); }

    public static void main(String[] args) throws Exception {
        File w = new File(args[0]);
        Set<String> none = Collections.emptySet();
        List<String> a = Arrays.asList("a");

        check("absent + kept + not gone is kept", set("a").equals(DozeAppsMirror.absentKept(none, a, set("a"), none)));
        check("absent + kept + gone is dropped", DozeAppsMirror.absentKept(none, a, set("a"), set("a")).isEmpty());
        check("absent + not kept is dropped", DozeAppsMirror.absentKept(none, a, set("z"), none).isEmpty());
        check("installed names are never returned, kept or not",
                DozeAppsMirror.absentKept(set("a"), a, set("a"), none).isEmpty());
        check("mixed record keeps only the absent, kept, not gone name",
                set("a").equals(DozeAppsMirror.absentKept(set("i"), Arrays.asList("i", "a", "b", "c"),
                        set("i", "a", "c"), set("c"))));
        check("an unreadable keep record (null) keeps every absent name not gone",
                set("a").equals(DozeAppsMirror.absentKept(set("i"), Arrays.asList("a", "b", "i"), null, set("b"))));
        check("an empty record is empty", DozeAppsMirror.absentKept(none, Collections.<String>emptyList(), set("a"), none).isEmpty());

        File k = new File(w, "keep");
        write(k, "a\nb\tondemand\nc\tinstalled\tgroup:x\n\n   \n# comment\n  d  \n");
        check("keptPackages reads the package field of every real line", set("a", "b", "c", "d").equals(DozeAppsMirror.keptPackages(k)));
        Set<String> absent = DozeAppsMirror.keptPackages(new File(w, "nothing"));
        check("an absent keep file carries nothing (empty, not null)", absent != null && absent.isEmpty());
        File dir = new File(w, "adir");
        check("a directory in the file's place is unreadable (null)", dir.mkdir() && DozeAppsMirror.keptPackages(dir) == null);

        File k2 = new File(w, "keep2");
        write(k2, "b\tondemand\n");
        check("a mode-bearing keep line still keeps its recorded name",
                set("b").equals(DozeAppsMirror.absentKept(none, Arrays.asList("b"), DozeAppsMirror.keptPackages(k2), none)));

        System.out.println(fails == 0 ? "doze-absent: all cases pass" : "doze-absent: " + fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
