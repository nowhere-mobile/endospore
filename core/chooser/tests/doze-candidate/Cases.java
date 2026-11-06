import java.util.Arrays;
import java.util.Collection;

/** NWP-20261114-26 (Q052, docs/product-decisions.md 2026-10-20): DozeAppsMirror.choiceEligible, the rule
 *  DozeAppsMirror.candidate delegates to. A bundled app's Unrestricted choice is a profile's own, like a
 *  user-installed app's; only the curated push set, gmscompat and system uids stay out. The curated values come
 *  from the lifted ChooserActivity.PUSH_DOZE_PKGS, never retyped here. Exit 1 when any case fails. */
public class Cases {
    static int fail = 0;

    static void check(boolean cond, String label) {
        System.out.println((cond ? "  ok    " : "  FAIL  ") + label);
        if (!cond) fail++;
    }

    public static void main(String[] args) {
        Collection<String> curated = Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS);
        String bundled = "org.example.bundled";

        boolean real = ChooserActivity.PUSH_DOZE_PKGS.length >= 3;
        for (String p : ChooserActivity.PUSH_DOZE_PKGS) real &= p != null && !p.isEmpty();
        check(real, "control: the lifted PUSH_DOZE_PKGS holds 3 or more non-empty names");
        check(!curated.contains(bundled), "control: the bundled-style name is not in the curated set");

        check(DozeAppsMirror.choiceEligible(bundled, 10088, true, curated),
                "a bundled-style app (appId 10088) on the allow-list is a choice");
        check(!DozeAppsMirror.choiceEligible(bundled, 10088, false, curated),
                "the same app not on the allow-list is not a choice");
        check(!DozeAppsMirror.choiceEligible(bundled, 1000, true, curated), "appId 1000 is never a choice");
        check(!DozeAppsMirror.choiceEligible(bundled, 9999, true, curated), "appId 9999 is never a choice");
        check(DozeAppsMirror.choiceEligible(bundled, 10000, true, curated), "appId 10000 (the first app uid) is a choice");
        for (String p : ChooserActivity.PUSH_DOZE_PKGS) {
            check(!DozeAppsMirror.choiceEligible(p, 10088, true, curated), "curated " + p + " is never a choice");
        }
        check("app.grapheneos.gmscompat".equals(DozeAppsMirror.GMSCOMPAT_PKG),
                "GMSCOMPAT_PKG names GrapheneOS's gmscompat");
        check(!DozeAppsMirror.choiceEligible(DozeAppsMirror.GMSCOMPAT_PKG, 10088, true, curated),
                "gmscompat is never a choice");
        check(!DozeAppsMirror.choiceEligible(null, 10088, true, curated), "a null package is never a choice");
        check(!DozeAppsMirror.choiceEligible("", 10088, true, curated), "an empty package is never a choice");

        System.out.println(fail == 0 ? "doze-candidate: every case passes" : "doze-candidate: " + fail + " case(s) FAILED");
        System.exit(fail == 0 ? 0 : 1);
    }
}
