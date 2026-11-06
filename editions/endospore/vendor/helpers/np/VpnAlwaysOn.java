package np;

import java.lang.reflect.InvocationTargetException;
import java.util.List;

// #159 Slice 1 helper: establish (or clear) an always-on VPN for a specific (roamed) user via the framework
// enforcement API IVpnManager.setAlwaysOnVpnPackage(userId, pkg, lockdown, allowlist) -- the same API the
// Settings UI / DPM use, which works POST-restore on a RUNNING user (unlike writing the secure setting, which
// the framework only reads at user-start). Run as su 0 (uid 0) so it passes enforceCallingOrSelfPermission(
// CONTROL_ALWAYS_ON_VPN) + the cross-user check (checkComponentPermission grants uid 0 all permissions).
//
// NWP-20261010-15: a third mode, `defer`, carries a captured "Block connections without VPN" ON across a sign-out
// without cutting the fresh session off before its tunnel is up (docs/product-decisions.md, 2026-10-10, extending
// 2026-09-25). It records the VPN app's consent -- IVpnManager.setVpnPackageAuthorization(pkg, userId,
// TYPE_VPN_SERVICE) -- which on Endospore is exactly the path vpn-lockdown-on-first-connect.sh patches: always-on now,
// `nowhere_vpn_lockdown_pending` recorded, and the block armed at the tunnel's first connection, all under one lock in
// system_server, with an arm attempt posted in case the tunnel is already up. Doing the same from out here (always-on
// without the block, then the pending setting) would race a tunnel that connects between the two writes. The call
// returns nothing, so roamd reads the settings back to see what it did.
//
// Args: <userId> <pkg|""=clear> <0 | 1 | defer>. Errors print `ERR <exception class>` only, never a message.
// The binder calls are made by reflection so the sync-javac harness can compile this file against small fakes.
public class VpnAlwaysOn {
    static final int TYPE_VPN_SERVICE = 1; // android.net.VpnManager.TYPE_VPN_SERVICE

    public static void main(String[] a) {
        String r;
        try {
            r = run(a);
        } catch (Throwable t) {
            Throwable c = t;
            while (c instanceof InvocationTargetException && c.getCause() != null) {
                c = c.getCause();
            }
            r = "ERR " + c.getClass().getSimpleName();
        }
        System.out.println(r);
    }

    static String run(String[] a) throws Exception {
        int userId = Integer.parseInt(a[0]);
        String pkg = (a.length > 1 && !a[1].isEmpty()) ? a[1] : null;
        String mode = a.length > 2 ? a[2] : "0";
        Object b = Class.forName("android.os.ServiceManager").getMethod("getService", String.class)
                .invoke(null, "vpn_management");
        if (b == null) {
            return "ERR: no vpn_management service"; // what an SELinux find denial looks like from here
        }
        Object mgr = Class.forName("android.net.IVpnManager$Stub")
                .getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, b);
        Class<?> vm = Class.forName("android.net.IVpnManager");
        if ("defer".equals(mode)) {
            if (pkg == null) {
                return "ERR: defer needs a package";
            }
            vm.getMethod("setVpnPackageAuthorization", String.class, int.class, int.class)
                    .invoke(mgr, pkg, userId, TYPE_VPN_SERVICE);
            return "setVpnPackageAuthorization(user=" + userId + ", pkg=" + pkg + ", type=" + TYPE_VPN_SERVICE
                    + ") -> done";
        }
        boolean lockdown = mode.equals("1");
        Object r = vm.getMethod("setAlwaysOnVpnPackage", int.class, String.class, boolean.class, List.class)
                .invoke(mgr, userId, pkg, lockdown, null);
        return "setAlwaysOnVpnPackage(user=" + userId + ", pkg=" + pkg + ", lockdown=" + lockdown + ") -> " + r;
    }
}
