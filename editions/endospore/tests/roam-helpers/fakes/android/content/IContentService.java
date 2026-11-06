package android.content;

import android.accounts.Account;

// roam-helpers fake of the six methods np.SyncRoam calls, with the real signatures.
public interface IContentService {
    SyncAdapterType[] getSyncAdapterTypesAsUser(int userId);

    String[] getSyncAdapterPackagesForAuthorityAsUser(String authority, int userId);

    boolean getMasterSyncAutomaticallyAsUser(int userId);

    void setMasterSyncAutomaticallyAsUser(boolean flag, int userId);

    boolean getSyncAutomaticallyAsUser(Account account, String providerName, int userId);

    void setSyncAutomaticallyAsUser(Account account, String providerName, boolean sync, int userId);

    abstract class Stub {
        public static IContentService asInterface(android.os.IBinder b) {
            return (IContentService) ((android.os.FakeBinder) b).impl;
        }
    }
}
