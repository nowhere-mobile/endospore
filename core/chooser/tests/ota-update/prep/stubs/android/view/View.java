package android.view;

/** Stub for the prep harness (NWP-20261113-22): records every visibility write. */
public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;
    public int visibility = GONE;
    public int writes;

    public void setVisibility(int v) { visibility = v; writes++; }
    public int getVisibility() { return visibility; }
}
