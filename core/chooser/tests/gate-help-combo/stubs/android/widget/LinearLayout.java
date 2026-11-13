package android.widget;
import android.content.Context;
import android.view.ViewGroup;
public class LinearLayout extends ViewGroup {
    public static final int HORIZONTAL = 0;
    public static final int VERTICAL = 1;
    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public float weight;
        public LayoutParams(int w, int h) { super(w, h); }
        public LayoutParams(int w, int h, float weight) { super(w, h); this.weight = weight; }
    }
    public LinearLayout(Context c) { super(c); }
    public void setOrientation(int o) {}
    public void setGravity(int g) {}
    public void setBaselineAligned(boolean b) {}
}
