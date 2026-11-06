/**
 * Cases for StoreService.mayMaterializeOwn (NWP-20261119-19). core/vendor-common/bin/test-napps-action-java.sh lifts
 * the materialize-own fence into a class OwnGate and compiles it with this file: only an archived placeholder
 * (no code, the archived record resolves) in the deferred keep-set may start the sealed materialise.
 */
public class OwnGateCases {
    public static void main(String[] a) {
        int failed = 0, run = 0;
        for (int i = 0; i < 8; i++) {
            boolean hasCode = (i & 4) != 0, archived = (i & 2) != 0, kept = (i & 1) != 0;
            boolean want = !hasCode && archived && kept;
            boolean got = OwnGate.mayMaterializeOwn(hasCode, archived, kept);
            run++;
            if (got != want) {
                failed++;
                System.out.println("FAIL G hasCode=" + hasCode + " archived=" + archived + " kept=" + kept
                        + ": want " + want + ", got " + got);
            }
        }
        System.out.println(run + " gate cases, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
