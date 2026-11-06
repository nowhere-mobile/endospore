package android.system;

// roam-helpers fake: the process uid and gid. Like the kernel, only root may change its gid to another: a process that
// dropped its uid first can no longer set its gid (EPERM), which is why the real helper must setgid BEFORE setuid.
public final class Os {
    public static int uid = 0, gid = 0;
    // A setuid that returns without changing anything -- what the helper must notice and refuse to go on from.
    public static boolean silentSetuid = false;

    public static int getuid() {
        return uid;
    }

    public static void setuid(int u) throws Exception {
        if (silentSetuid) {
            return;
        }
        if (uid != 0 && u != uid) {
            throw new Exception("EPERM");
        }
        uid = u;
    }

    public static void setgid(int g) throws Exception {
        if (uid != 0 && g != gid) {
            throw new Exception("EPERM");
        }
        gid = g;
    }
}
