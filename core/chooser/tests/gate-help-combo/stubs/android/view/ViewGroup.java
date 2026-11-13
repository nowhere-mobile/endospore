package android.view;
import android.content.Context;
import java.util.ArrayList;
import java.util.List;
public class ViewGroup extends View {
    public static class LayoutParams {
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;
        public int width, height;
        public LayoutParams(int w, int h) { width = w; height = h; }
    }
    public static class MarginLayoutParams extends LayoutParams {
        public int leftMargin, topMargin, rightMargin, bottomMargin;
        public MarginLayoutParams(int w, int h) { super(w, h); }
    }
    private final List<View> kids = new ArrayList<>();
    public ViewGroup(Context c) { super(c); }
    public void addView(View v) { kids.add(v); }
    public void addView(View v, LayoutParams p) { v.setLayoutParams(p); kids.add(v); }
    public int getChildCount() { return kids.size(); }
    public View getChildAt(int i) { return kids.get(i); }
}
