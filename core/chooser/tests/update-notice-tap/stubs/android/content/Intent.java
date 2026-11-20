package android.content;

import java.util.HashMap;
import java.util.Map;

/** NWP-20261208-32 stub: records the component, the string extras and the flags (AOSP values). */
public class Intent {
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public static final int FLAG_ACTIVITY_SINGLE_TOP = 0x20000000;

    public String pkg;
    public String cls;
    public int flags;
    public final Map<String, String> extras = new HashMap<>();

    public Intent() {}

    public Intent setClassName(Context c, String cls) { this.pkg = c.getPackageName(); this.cls = cls; return this; }

    public Intent setClassName(String pkg, String cls) { this.pkg = pkg; this.cls = cls; return this; }

    public Intent putExtra(String k, String v) { extras.put(k, v); return this; }

    public String getStringExtra(String k) { return extras.get(k); }

    public void removeExtra(String k) { extras.remove(k); }

    public Intent addFlags(int f) { flags |= f; return this; }

    public int getFlags() { return flags; }
}
