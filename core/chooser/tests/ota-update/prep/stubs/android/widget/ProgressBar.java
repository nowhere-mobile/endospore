package android.widget;

/** Stub for the prep harness (NWP-20261113-22): records every mode, progress and visibility write. */
public class ProgressBar extends android.view.View {
    public boolean indeterminate;
    public int progress;

    public void setIndeterminate(boolean on) { indeterminate = on; writes++; }
    public boolean isIndeterminate() { return indeterminate; }
    public void setProgress(int p) { progress = p; writes++; }
}
