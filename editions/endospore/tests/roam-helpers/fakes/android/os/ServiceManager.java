package android.os;

import java.util.HashMap;
import java.util.Map;

// roam-helpers fake: a name -> binder table the cases fill. An absent name answers null, which is what an SELinux
// find denial looks like to the real helpers.
//
// THE BINDER CALLER IS THE UID THAT OPENED /dev/binder, not the uid the process has when it calls: the driver keeps
// the opener's credentials. app_process opens it before main() runs, so a process the suite starts "as roamd" begins
// with openedAs = 0, and a fresh child process starts with openedAs unset -- it is fixed at its first getService, from
// the fake Os uid at that moment. The fake services read the caller from here.
public final class ServiceManager {
    public static final Map<String, IBinder> SERVICES = new HashMap<>();
    public static Integer openedAs = null;

    public static IBinder getService(String name) {
        if (openedAs == null) {
            openedAs = android.system.Os.getuid();
        }
        return SERVICES.get(name);
    }
}
