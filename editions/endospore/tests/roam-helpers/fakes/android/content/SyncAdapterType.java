package android.content;

// roam-helpers fake: the two public fields np.SyncRoam reads.
public class SyncAdapterType {
    public final String authority, accountType;

    public SyncAdapterType(String authority, String accountType) {
        this.authority = authority;
        this.accountType = accountType;
    }
}
