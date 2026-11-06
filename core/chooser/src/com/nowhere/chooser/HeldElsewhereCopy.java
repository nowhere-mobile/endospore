package com.nowhere.chooser;

/**
 * The words Apps this device is holding puts on screen about the apps ANOTHER device holds (NWP-20261120-15). They
 * live here so a javac suite can pin them.
 *
 * The shape is decided in docs/product-decisions.md, 2026-09-12: "two handsets MAY be signed in at once" gave a
 * read-only list of held packages and the device holding each, on one screen; "a handset can let go of its own holds,
 * and can ASK another handset to let go of one" gave THIS device's holds a Release, so the other device's holds get
 * no control here; and "name the other device only when its name is not ambiguous" names the holder ("Same, or
 * unknown -- render "your other device""; the word is device). The 2026-09-11 question they answer scoped it: what
 * is HELD, not what is running, no take-it-back control, no timeout control, one screen.
 *
 * The release conditions in {@link #body} are the ones {@code AppClaim.hold}'s dialog states, so the screen and the
 * tap on a held app tell the user the same thing.
 */
final class HeldElsewhereCopy {
    private HeldElsewhereCopy() {}

    /**
     * The holder, by the 2026-09-12 rule's unknown-name branch. The seal writes a holder's name into the claim record
     * only when it differs from this phone's label (h54 #1, NWP-20261125-06); a package with no name says this.
     */
    static final String WHERE = "your other device";

    /** The heading over the list when no holder is named: {@code heading(null)}. */
    static final String HEADING = "Held by " + WHERE;

    /** Shown in place of the list when the claim record is present but cannot be read: never "nothing held". */
    static final String UNREADABLE = "Couldn't read which apps your other device is holding right now.";

    /** The heading over one holder's apps: "Held by <holder>", or HEADING for a null, empty or WHERE holder. */
    static String heading(String holder) {
        return "Held by " + where(holder);
    }

    /** {@code body(labels, null)}: the text for apps held where the record names no holder. */
    static String body(java.util.List<String> labels) {
        return body(labels, null);
    }

    /**
     * One "• label" line per app in the given order, a blank line, then when each opens here, naming the holder (or
     * WHERE for a null, empty or WHERE holder). Null for a null or empty list: the section is then not drawn, so a
     * profile signed in on one device sees nothing new.
     */
    static String body(java.util.List<String> labels, String holder) {
        if (labels == null || labels.isEmpty()) return null;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < labels.size(); i++) {
            sb.append("• ").append(labels.get(i)).append("\n");
        }
        sb.append("\nThese are in use on ").append(where(holder)).append(", so they won't open here. Each opens ")
          .append("here once that device releases it, signs out or uninstalls it, or about fifteen minutes after ")
          .append("that device is switched off.");
        return sb.toString();
    }

    /** The holder as named on screen: the record's name, else WHERE (the 2026-09-12 rule's unknown branch). */
    private static String where(String holder) {
        return holder == null || holder.isEmpty() ? WHERE : holder;
    }
}
