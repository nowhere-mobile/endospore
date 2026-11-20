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
 *  lines. Nothing existed to restore, so the creating screen gets "Setting up ..." labels, one per scope as well.
 *
 *  NWP-20261208-30 (design NWP-20261116-48, approved by Chester 2026-11-17): a sign-in shows each label once, one bar
 *  each, in this order: Restoring app data, Restoring secure data, Restoring your accounts, Restoring photos and files,
 *  Restoring your apps, then Finishing up… (the gate's finish block paints the last one, not this class). roamd's
 *  post-media cleanup (`finishing`) is the tail of the media restore, so it reads as photos and files; the #keys restore
 *  (`keys`, from the agent half D08a) is the tail of the apps restore, so it reads as your apps. hold() keeps each tail
 *  on its scope's bar. The creating labels are not in that design and stay as they were. With an older roamd the keys
 *  restore still says `data` and reads "Restoring your profile", as before. */
final class RestorePhase {
    private RestorePhase() {}

    static String label(String phase, boolean creating) {
        if (phase == null) phase = "";
        switch (phase) {
            case "apps":      return creating ? "Setting up app data" : "Restoring app data";           // the CE scope (bare name)
            case "accounts":  return creating ? "Setting up your accounts" : "Restoring your accounts"; // #sys (roamd tags it `accounts` since D7)
            case "appcode":   return creating ? "Setting up your apps" : "Restoring your apps";         // #apps (roamd tags it `appcode` since D7)
            case "keys":      return creating ? "Setting up your apps" : "Restoring your apps";         // #keys (tagged `keys` since D08a), the apps restore's tail
            case "secure":    return creating ? "Setting up secure data" : "Restoring secure data";     // #de
            case "media":     return creating ? "Setting up photos & files" : "Restoring photos and files";
            case "finishing": return creating ? "Setting up photos & files" : "Restoring photos and files"; // roamd's post-media cleanup (_restore_tail_prog)
            default:          return creating ? "Setting up your profile" : "Restoring your profile";
        }
    }

    /** One bar per label: within one label the shown percent never goes back. The cleanup's 1/n after the media
     *  restore's 100%, the keys restore's 0% after the apps restore's 100%, and an older agent's heal pass restarting app
     *  data at 0% all hold the bar where it was. A NEW label may start low (#113: a reset between scopes is legible).
     *  prevLabel is null before the first line of a sign-in. */
    static int hold(String prevLabel, int prevPct, String label, int pct) {
        return prevLabel != null && prevLabel.equals(label) && pct < prevPct ? prevPct : pct;
    }
}
