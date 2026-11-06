package com.nowhere.chooser;

import android.system.Os;
import android.system.OsConstants;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;

/**
 * NWP-20260930-03: owner.conf -- the device passphrase's salt, verifier and failure count -- written atomically.
 *
 * ChooserActivity.writeOwnerConf used to truncate the file and then write it (openFileOutput), at every enrol and
 * every verify, success or failure. A crash or power loss in that window left it empty or half-written. An empty
 * owner.conf reads as "no owner secret" (ownerSecretSet), so the next boot sends the gate to the required enrol --
 * and an enrol mints a new device-owner key under whoever holds the phone. A half-written one read as damaged
 * (readOwnerConf returned null) when the cut fell before "verifier=", and as a wrong passphrase when it fell inside
 * the verifier's value; the owner verify showed "wrong passphrase" for both: a permanent lockout that looked like a
 * typo. A cut after the verifier, in "fails=" or "last=", left a file that still verified, with its back-off reset.
 * Since this slice readOwnerConf also reads a salt or verifier VALUE of the wrong form as damaged. docs/backlog.md,
 * "A damaged `owner.conf` renders as "wrong passphrase"...".
 *
 * The write goes to a temp file in the same directory, is synced, and is renamed over owner.conf, so after a crash
 * the file is either the old one or the new one; the directory is then synced to make the rename durable. The body
 * is never logged: on a phone without StrongBox the verifier is the PBKDF2 output of the passphrase.
 */
final class OwnerConf {
    private OwnerConf() {}

    /** Shown at the owner verify when owner.conf exists but cannot be parsed (verifyOwner returns -2). The words are
     *  docs/owner-identity-spec.md's for a damaged file with no reset code armed; no reset code exists yet. */
    static final String DAMAGED =
            "this phone's passphrase file is damaged — the passphrase can't be checked."
            + " Erasing the phone is the only way back into Owner settings.";

    /** Shown when the attempt could not be counted (verifyOwner returns -3): the passphrase was not checked. */
    static final String NOT_COUNTED = "can't check the passphrase right now — try again";

    /** NWP-20261120-04 (#26, Q018): what the owner key HMACs to make owner.conf's key-check value (kcv). A fixed
     *  constant, so the kcv says which chip key is there and nothing about the passphrase. */
    static final String KCV_CONST = "nowhere-owner-kcv-v1";

    /** NWP-20261120-04: owner.conf's body. The kcv line is written only when kcv is set, so a conf with no kcv keeps the
     *  bytes it had before this slice (an older chooser's reader ignores a key it does not know). */
    static String body(String saltHex, String verifier, int fails, long last, String kcv) {
        return "v1\nsalt=" + saltHex + "\nverifier=" + verifier + "\nfails=" + fails + "\nlast=" + last + "\n"
                + (kcv == null || kcv.isEmpty() ? "" : "kcv=" + kcv + "\n");
    }

    /** Writes body to f atomically. True when the new contents are in place, their file synced. A failed directory
     *  sync after the rename does not make it false: the new contents are already what every reader sees, and a false
     *  would have verifyOwner say "not counted" of an attempt owner.conf has counted. */
    static boolean write(File f, byte[] body) {
        File dir = f.getParentFile();
        File tmp = new File(dir, "." + f.getName() + ".tmp");
        try {
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(body);
                out.getFD().sync();
            }
            Os.rename(tmp.getPath(), f.getPath());
        } catch (Throwable t) {
            tmp.delete();
            android.util.Log.e("NowhereChooser", "owner.conf write failed: " + t.getClass().getSimpleName());
            return false;
        }
        try {
            FileDescriptor d = Os.open(dir.getPath(), OsConstants.O_RDONLY, 0);
            try {
                Os.fsync(d);
            } finally {
                Os.close(d);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "owner.conf directory sync failed: " + t.getClass().getSimpleName());
        }
        return true;
    }
}
