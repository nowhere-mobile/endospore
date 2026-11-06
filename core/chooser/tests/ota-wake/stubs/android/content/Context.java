package android.content;

import java.util.HashMap;
import java.util.Map;

/** Returns itself as the application context; getSystemService answers from a map the cases fill. */
public class Context {
    public static final String ALARM_SERVICE = "alarm";
    public static final String CONNECTIVITY_SERVICE = "connectivity";
    public final Map<String, Object> services = new HashMap<>();
    public Context getApplicationContext() { return this; }
    public Object getSystemService(String name) { return services.get(name); }
}
