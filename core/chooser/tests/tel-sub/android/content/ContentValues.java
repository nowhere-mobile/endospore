package android.content;

import java.util.HashMap;
import java.util.Map;

/** The two members TelSub.file uses, so it compiles and runs with no Android SDK. */
public final class ContentValues {
    private final Map<String, Object> values = new HashMap<>();

    public void put(String key, Integer value) { values.put(key, value); }

    public Object get(String key) { return values.get(key); }
}
