package android.content;

public class Intent {
    public static final String ACTION_POWER_CONNECTED = "android.intent.action.ACTION_POWER_CONNECTED";
    private String action;
    public Intent() {}
    public Intent(Context c, Class<?> cls) {}
    public Intent setAction(String a) { action = a; return this; }
    public String getAction() { return action; }
}
