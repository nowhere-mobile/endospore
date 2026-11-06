package com.nowhere.chooser;

/** The label for one scope of a restore's progress stream (pure Java, no android.*, so a javac suite runs it).
 *
 *  D7 (NWP-20260823-04): one label PER SCOPE. Three scopes used to share the "apps" tag, so "Restoring app data"
 *  appeared three separate times with the bar resetting to 0% each time -- an illegible reset. With distinct tags every
 *  reset arrives under a NEW label, which is the #113 principle ("a reset between scopes is LEGIBLE") finished. Unknown
 *  tags still fall through to the generic label, so an old roamd against this chooser (or the reverse) degrades to
 *  exactly the old behaviour.
 *
 *  NWP-20261027-11: a create writes the first vault and then signs in, and that sign-in's restore streams the same
 *  lines. Nothing existed to restore, so the creating screen gets "Setting up ..." labels, one per scope as well. */
final class RestorePhase {
    private RestorePhase() {}

    static String label(String phase, boolean creating) {
        if (phase == null) phase = "";
        switch (phase) {
            case "apps":     return creating ? "Setting up app data" : "Restoring app data";           // the CE scope (bare name)
            case "accounts": return creating ? "Setting up your accounts" : "Restoring your accounts"; // #sys (roamd tags it `accounts` since D7)
            case "appcode":  return creating ? "Setting up your apps" : "Restoring your apps";         // #apps (roamd tags it `appcode` since D7)
            case "secure":   return creating ? "Setting up secure data" : "Restoring secure data";     // #de
            case "media":    return creating ? "Setting up photos & files" : "Restoring photos & files";
            default:         return creating ? "Setting up your profile" : "Restoring your profile";
        }
    }
}
