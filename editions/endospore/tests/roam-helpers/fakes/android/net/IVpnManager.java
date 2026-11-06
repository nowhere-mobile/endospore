package android.net;

import java.util.List;

// roam-helpers fake of the two methods np.VpnAlwaysOn calls, with the real signatures.
public interface IVpnManager {
    void setVpnPackageAuthorization(String packageName, int userId, int vpnType);

    boolean setAlwaysOnVpnPackage(int userId, String packageName, boolean lockdown, List<String> lockdownAllowlist);

    abstract class Stub {
        public static IVpnManager asInterface(android.os.IBinder b) {
            return (IVpnManager) ((android.os.FakeBinder) b).impl;
        }
    }
}
