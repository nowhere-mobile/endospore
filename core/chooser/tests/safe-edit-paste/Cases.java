// NWP-20261114-21 (Q041): SafeEdit.pasteAllowed, lifted by core/chooser/tests/safe-edit-paste/run.sh. Paste is
// offered only when the box wants it (the report and claim-code boxes) AND the ClipboardManager is reachable.
public final class Cases {
    private static int bad = 0;

    private static void check(boolean wanted, boolean reachable, boolean expect) {
        boolean got = SafeEdit.pasteAllowed(wanted, reachable);
        String line = "pasteAllowed(wanted=" + wanted + ", reachable=" + reachable + ") = " + got;
        if (got == expect) {
            System.out.println("  ok    " + line);
        } else {
            System.out.println("  FAIL  " + line + ", want " + expect);
            bad++;
        }
    }

    public static void main(String[] args) {
        check(false, false, false); // a plain SafeEdit on an image without the grant
        check(false, true, false);  // a plain SafeEdit (a gate field) on an image with the grant
        check(true, false, false);  // a withPaste box on an image without the grant
        check(true, true, true);    // a withPaste box on an image with the grant
        System.exit(bad == 0 ? 0 : 1);
    }
}
