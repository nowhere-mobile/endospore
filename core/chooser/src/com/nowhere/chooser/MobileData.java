package com.nowhere.chooser;

/**
 * The Profile screen's Mobile data switch: what is stored, who is offered it, what the switch shows and what the toast
 * may say (NWP-20261026-07; docs/product-decisions.md, 2026-10-19). A profile's choice is its own, kept in its
 * nowhere-prefs as {@code mobiledata=1} or {@code mobiledata=0}; roamd applies it only while the session is in front
 * and puts the gate's value back at every release path (nowhere_roamd.sh, the SESSION-SCOPED MOBILE DATA block).
 * Unlike Location services, the baseline is the gate's own value, not Off, so a profile with no choice stored is not
 * Off: it reads as "no choice" and the switch shows what the phone has.
 *
 * Pure Java, no android.* import: core/chooser/test-mobile-data-java.sh compiles this file directly.
 */
final class MobileData {
    private MobileData() {}

    /** The nowhere-prefs key roamd's md_choice reads. */
    static final String PREF = "mobiledata";

    /** A stored value as a choice: "1" (On), "0" (Off), or "" (no choice -- the gate's value). Blanks are trimmed;
     *  anything else, "2" and "true" included, is no choice, which is roamd's rule. */
    static String choice(String v) {
        if (v == null) return "";
        String t = v.trim();
        return "1".equals(t) || "0".equals(t) ? t : "";
    }

    /** Whether Preferences offers Mobile data: only to a STORED session that is not an offline sign-in. Both editions
     *  have mobile data, so unlike Location services there is no provider condition. A throwaway (LOCAL), an offline
     *  sign-in (LOCAL too) and a session whose type the probe could not learn (UNKNOWN) are not offered it. This
     *  follows Chester's 2026-10-17 answer for Location services ("lets keep throwaway simple for now, so leave it
     *  out") as an INFERENCE the decision record asks him to confirm; it was not asked about mobile data itself. */
    static boolean offered(String sessionType, boolean offline) {
        return !offline && "STORED".equals(sessionType);
    }

    /** The switch's state: the stored choice, or -- with none -- what the phone has now. phoneOn is null when the
     *  phone could not be asked, and then the switch shows Off. */
    static boolean switchChecked(String choice, Boolean phoneOn) {
        String c = choice(choice);
        if ("1".equals(c)) return true;
        if ("0".equals(c)) return false;
        return phoneOn != null && phoneOn;
    }

    /** The value roamd read back, from its "OK APPLIED mobile_data=<v>" answer to APPLY-MOBILE-DATA; "" for any other
     *  answer (ERR-MD, SKIP-ENDED, NONE, nothing at all) or one that does not carry it. */
    static String replyValue(String reply) {
        if (reply == null || !reply.startsWith("OK APPLIED ")) return "";
        for (String tok : reply.substring("OK APPLIED ".length()).trim().split(" ")) {
            if (tok.startsWith("mobile_data=")) return tok.substring("mobile_data=".length());
        }
        return "";
    }

    /** True when roamd read mobile data back as this tap asked: 1 for On, 0 for Off. */
    static boolean applied(String reply, boolean on) {
        return (on ? "1" : "0").equals(replyValue(reply));
    }

    /** The toast after a switch, or null for none. stillChosen says whether the profile's stored choice still is what
     *  this tap asked when the answer comes back: when it is not, a later tap replaced it and that tap's own request
     *  reports. Otherwise what was applied, or -- when roamd did not read this tap's value back -- that the choice is
     *  saved and when it takes effect at the latest. Never claims a change roamd did not read back. */
    static String applyToast(boolean on, String reply, boolean stillChosen) {
        if (!stillChosen) return null;
        String what = on ? "Mobile data on" : "Mobile data off";
        if (!applied(reply, on)) {
            return what + " is saved with this profile, but the phone hasn't confirmed the change yet — it takes "
                    + "effect when you next sign in or come back from standby, at the latest";
        }
        return what + " — only while you're signed in to this profile";
    }

    /** The toast when the switch's write to nowhere-prefs failed, or null for none. nowOn is what the screen shows
     *  after the redraw from the file, not what was tapped, and the toast says the phone is at it only when roamd read
     *  that value back. stillChosen as in applyToast. */
    static String notSavedToast(boolean nowOn, String reply, boolean stillChosen) {
        if (!stillChosen) return null;
        String head = "Mobile data: the change couldn't be saved on this phone. ";
        if (!applied(reply, nowOn)) {
            return head + "This profile's setting is " + (nowOn ? "on" : "off") + ", but the phone hasn't confirmed it "
                    + "yet — it takes effect when you next sign in or come back from standby, at the latest";
        }
        return head + "Mobile data is now " + (nowOn ? "on" : "off") + ", only while you're signed in to this profile";
    }

    // ---- Data roaming (NWP-20261028-09): the same switch screen, the same baseline (the gate's value), a second key.
    // roamd claims and restores it beside mobile data and answers "OK APPLIED mobile_data=<v> data_roaming=<0|1|?>".

    /** The nowhere-prefs key roamd reads for the profile's data roaming choice. */
    static final String ROAM_PREF = "dataroaming";

    /** A stored data roaming value as a choice: choice's rules, so "1", "0" or "" (no choice -- the gate's value). */
    static String roamChoice(String v) {
        return choice(v);
    }

    /** The value roamd read back, from the " data_roaming=<v>" token of an "OK APPLIED ..." answer; "" for any other
     *  answer, one without the token (an older roamd) and one that reads "?". Never a guess. */
    static String roamReplyValue(String reply) {
        if (reply == null || !reply.startsWith("OK APPLIED ")) return "";
        for (String tok : reply.substring("OK APPLIED ".length()).trim().split(" ")) {
            if (tok.startsWith("data_roaming=")) {
                String v = tok.substring("data_roaming=".length());
                return "1".equals(v) || "0".equals(v) ? v : "";
            }
        }
        return "";
    }

    /** True when roamd read data roaming back as this tap asked: 1 for On, 0 for Off. */
    static boolean roamApplied(String reply, boolean on) {
        return (on ? "1" : "0").equals(roamReplyValue(reply));
    }

    /** applyToast's rules for the Data roaming switch. */
    static String roamApplyToast(boolean on, String reply, boolean stillChosen) {
        if (!stillChosen) return null;
        String what = on ? "Data roaming on" : "Data roaming off";
        if (!roamApplied(reply, on)) {
            return what + " is saved with this profile, but the phone hasn't confirmed the change yet — it takes "
                    + "effect when you next sign in or come back from standby, at the latest";
        }
        return what + " — only while you're signed in to this profile";
    }

    /** notSavedToast's rules for the Data roaming switch. */
    static String roamNotSavedToast(boolean nowOn, String reply, boolean stillChosen) {
        if (!stillChosen) return null;
        String head = "Data roaming: the change couldn't be saved on this phone. ";
        if (!roamApplied(reply, nowOn)) {
            return head + "This profile's setting is " + (nowOn ? "on" : "off") + ", but the phone hasn't confirmed it "
                    + "yet — it takes effect when you next sign in or come back from standby, at the latest";
        }
        return head + "Data roaming is now " + (nowOn ? "on" : "off") + ", only while you're signed in to this profile";
    }
}
