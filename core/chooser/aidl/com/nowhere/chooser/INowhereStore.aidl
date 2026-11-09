package com.nowhere.chooser;

/**
 * The storefront's data channel, exposed by the chooser to the separate nApps app (DIA-20260818-08, #747).
 *
 * WHY THIS EXISTS. nApps needs its own package so it appears in Settings > Apps as its own app, but the
 * login daemon PINS the first peer's appId on the login socket and rejects every other one
 * (SO_PEERCRED trust-on-first-use, main.go:4136-4146 -- "a roamed app would be a different package").
 * That control came out of audit #2 (DIA-20260618-08) and is worth keeping, so the split does NOT relax it:
 * the chooser stays the ONLY package that ever opens the socket, and nApps asks it for what it needs.
 *
 * The install path is deliberately on this side of the boundary too. FETCH-APP stages verified bytes and the
 * install itself needs the chooser's privileged package-install permission -- precisely the authority a thin
 * UI package should not hold. nApps asks; the chooser decides and acts.
 *
 * Every call here is a blocking round-trip to a single-threaded daemon: callers MUST be off the main thread
 * (ProfileActivity ANR'd exactly this way once -- see the note above applyKeepModeOffThread).
 */
interface INowhereStore {
    /** The storefront's storage line, READY TO DISPLAY ("Storage: 1.2 GB of 10.0 GB used"); "" when there is
     *  nothing meaningful to say. NWP-20260825-20: this used to hand over the raw GET-ENTITLEMENT wire line
     *  ("OK used=.. free=.. entitled=.. covered=.. credit=.. gbpertoken=..") and nApps rendered it verbatim, so
     *  the storefront header showed debug output to users. The formatting belongs on the chooser side with the
     *  rest of the billing vocabulary -- nApps holds no authority and should not be parsing economics. */
    String getStorageLine();

    /** REFRESH-CATALOG: pull a fresh signed catalog. Best-effort; a stale catalog is still served after. */
    void refreshCatalog();

    /** GET-CATALOG -> the signed catalog JSON; "" on any failure. */
    String getCatalog();

    /** SEARCH-APPS <query> -> catalog-shaped JSON over the full signed index; "" on any failure. */
    String searchApps(String query);

    /** FETCH-ICON <url> -> raw icon bytes for an app not yet on the phone; null on any failure.
     *  data: URIs are decoded by the caller and never reach this call. */
    byte[] fetchIcon(String url);

    /** FETCH-APP <pkg>: download + sha256-verify + stage + INSTALL + keep. NWP-20260819-03: the install
     *  really is this side's job (the daemon stages, the chooser commits) -- until the fix this call
     *  skipped the commit, so "added" rendered while the APK sat parked in .appcode. The signer pin is the
     *  DAEMON's (its FETCH-APP OK names the cert of the entry it resolved from the signed catalog/index);
     *  it deliberately does NOT cross this boundary -- a caller-supplied pin was strippable with "".
     *  Replies: "OK <pkg>" (installed + kept, AUTO mode) | "OK-SESSION-ONLY <pkg>" (installed, keep refused
     *  by the #136 over-plan gate -- SAY SO) | "OK-UNSAVED <pkg>" (installed, but its keep line could not be
     *  written -- it will not come back; SAY SO) | "ERR-BUSY" (this pkg is already installing) | "ERR-PENDING"
     *  (still installing at InstallWait's 10-minute bound -- re-check, do not retry blindly) | "ERR-INSTALL"
     *  | "ERR-CALLER" | the daemon's own verdict (ERR-NOENTRY / ERR-OVERPLAN ... / NONE).
     *
     *  NWP-20260921-12: `label` is the catalog's display name, carried purely so the install NOTIFICATION
     *  can say "Adding NotePad" instead of "Adding com.example.notepad". The notice is posted BEFORE the
     *  download, when a brand-new package is by definition not installed, so PackageManager cannot supply
     *  it and the chooser's own lookup always fell through to the package id.
     *
     *  ⚠⚠ IT IS DISPLAY-ONLY AND CARRIES NO AUTHORITY -- exactly like the signer pin above, and for the
     *  same reason: a caller-supplied value can be anything, including "". It must never reach the signer
     *  pin, the keep decision, the over-plan gate or any identity check. Empty or blank means "no opinion",
     *  and the chooser falls back to PackageManager and then to the package id, so a hostile or missing
     *  label can only ever make the shade line less informative -- never wrong about WHAT is installed. */
    String getApp(String pkg, String label);

    /** REFRESH-INDEX (NWP-20261103-14, Q079): pull a fresh signed F-Droid index into /data so search and its
     *  download links stay current. Gated on THIS side: on a metered (or unreadable) network only when the live
     *  profile's "Download over mobile data" switch is on (GET-PREFETCH-METERED "1"). Appended LAST so every
     *  existing transaction code is unchanged. Replies: "OK" | "NONE" | "ERR" (the daemon's word) | "SKIPPED"
     *  (the gate said no; nothing was sent) | "ERR-CALLER" | "ERR no reply". Callers ignore the reply. */
    String refreshIndex();

    /** MATERIALIZE-OWN (NWP-20261119-19, h49 #1, Q051): materialise the session's own sealed copy of an On-demand app
     *  that is an archived placeholder in the caller's user and in the keep-set. Starts UnarchiveService as an
     *  unarchive tap does (no unarchive id), so the group materialise brings its Play dependencies and the progress
     *  queue applies; returns at once. Appended LAST so every existing transaction code is unchanged.
     *  Replies: "OK" | "ERR-CALLER" | "ERR-NOTARCHIVED" | "ERR". */
    String materializeOwn(String pkg);
}
