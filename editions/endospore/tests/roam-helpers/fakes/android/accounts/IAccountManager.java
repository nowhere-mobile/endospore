package android.accounts;

// roam-helpers fake of the one method np.SyncRoam calls.
public interface IAccountManager {
    Account[] getAccountsAsUser(String accountType, int userId, String opPackageName);

    abstract class Stub {
        public static IAccountManager asInterface(android.os.IBinder b) {
            return (IAccountManager) ((android.os.FakeBinder) b).impl;
        }
    }
}
