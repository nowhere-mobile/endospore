package android.content;
import android.content.res.Resources;
public class Context {
    private final Resources res = new Resources();
    public Resources getResources() { return res; }
    public void startActivity(Object intent) {}
}
