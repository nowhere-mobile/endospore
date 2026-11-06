// StoreScreenCopyCases (NWP-20261113-21, NWP-20261124-16): the Store settings message, the S3 fields' visibility and
// the subtitle for each GET-STORE state. run.sh compiles this
// in StoreScreenCopy's package (a same-package shim), so it reaches the package-private class.
public class StoreScreenCopyCases {
    static int failures = 0;

    static void check(String name, boolean ok, String detail) {
        if (ok) {
            System.out.println("ok " + name);
        } else {
            System.out.println("--- FAIL " + name + ": " + detail);
            failures++;
        }
    }

    static void eq(String name, String got, String want) {
        check(name, want.equals(got), "got \"" + got + "\", want \"" + want + "\"");
    }

    public static void main(String[] a) {
        final String managedMsg = "This phone saves to the managed Nowhere store.";
        final String keysetMsg = "a key is already set — re-enter both keys to change it";
        final String noneMsg = "no store yet — set one up to create or unlock a profile";

        String m = StoreScreenCopy.message(true, true, false);
        check("managed never says no store yet", !m.contains("no store yet"), "got \"" + m + "\"");
        check("managed never mentions keys", !m.toLowerCase().contains("key"), "got \"" + m + "\"");
        check("managed never mentions the S3 fields", !m.contains("S3"), "got \"" + m + "\"");
        eq("managed message", m, managedMsg);
        eq("managed wins over configured=no", StoreScreenCopy.message(false, true, false), managedMsg);

        eq("self-hosted with keys: today's string", StoreScreenCopy.message(true, false, true), keysetMsg);
        eq("no store: today's string", StoreScreenCopy.message(false, false, false), noneMsg);
        eq("configured, not managed, no keys: today's no-store string", StoreScreenCopy.message(true, false, false), noneMsg);

        check("isError(managed=false, keyset=true) is true", StoreScreenCopy.isError(false, true), "got false");
        check("isError(managed=true, keyset=false) is false", !StoreScreenCopy.isError(true, false), "got true");
        check("isError(managed=false, keyset=false) is false", !StoreScreenCopy.isError(false, false), "got true");

        // NWP-20261124-16, decision #15: a managed phone shows the managed state only.
        final String selfSub = "Where your encrypted data is saved. Point this device at an S3-compatible store.";
        check("showS3Fields(managed=true) is false", !StoreScreenCopy.showS3Fields(true), "got true");
        check("showS3Fields(managed=false) is true", StoreScreenCopy.showS3Fields(false), "got false");
        eq("subtitle(managed=false): today's string", StoreScreenCopy.subtitle(false), selfSub);
        String ms = StoreScreenCopy.subtitle(true);
        check("subtitle(managed=true) names no S3 store", !ms.contains("S3"), "got \"" + ms + "\"");
        eq("subtitle(managed=true)", ms, "Where your encrypted data is saved.");

        if (failures > 0) {
            System.out.println(failures + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all store-screen-copy cases passed");
    }
}
