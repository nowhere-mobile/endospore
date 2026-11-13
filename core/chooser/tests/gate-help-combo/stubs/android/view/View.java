package android.view;
import android.content.Context;
import android.content.res.Resources;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
/** Records what the cases read. A listener makes a view clickable, as the framework's does. */
public class View {
    public static final int IMPORTANT_FOR_ACCESSIBILITY_NO = 2;
    public interface OnClickListener { void onClick(View v); }
    private final Context context;
    private CharSequence description;
    private OnClickListener click;
    private boolean clickable;
    private int important;
    private Drawable background;
    private ViewGroup.LayoutParams params;
    private int w, h;
    public View(Context c) { context = c; }
    public Context getContext() { return context; }
    public Resources getResources() { return context.getResources(); }
    public void setContentDescription(CharSequence d) { description = d; }
    public CharSequence getContentDescription() { return description; }
    public void setOnClickListener(OnClickListener l) { click = l; if (l != null) clickable = true; }
    public boolean performClick() { if (click == null) return false; click.onClick(this); return true; }
    public void setClickable(boolean b) { clickable = b; }
    public boolean isClickable() { return clickable; }
    public void setFocusable(boolean b) {}
    public void setImportantForAccessibility(int m) { important = m; }
    public int getImportantForAccessibility() { return important; }
    public void setPadding(int l, int t, int r, int b) {}
    public void setBackground(Drawable d) { background = d; }
    public Drawable getBackground() { return background; }
    public void setBackgroundColor(int c) { background = new android.graphics.drawable.GradientDrawable(); ((android.graphics.drawable.GradientDrawable) background).setColor(c); }
    public void setMinimumHeight(int m) {}
    public void setStateListAnimator(android.animation.StateListAnimator a) {}
    public void setLayoutParams(ViewGroup.LayoutParams p) { params = p; }
    public ViewGroup.LayoutParams getLayoutParams() { return params; }
    public void layout(int l, int t, int r, int b) { w = r - l; h = b - t; }
    public int getWidth() { return w; }
    public int getHeight() { return h; }
    public void draw(Canvas c) { onDraw(c); }
    protected void onDraw(Canvas c) {}
}
