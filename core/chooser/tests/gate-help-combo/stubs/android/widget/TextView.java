package android.widget;
import android.content.Context;
import android.graphics.Typeface;
import android.view.View;
public class TextView extends View {
    private CharSequence text = "";
    private int color;
    public TextView(Context c) { super(c); }
    public void setText(CharSequence t) { text = t; }
    public CharSequence getText() { return text; }
    public void setTextColor(int c) { color = c; }
    public int getCurrentTextColor() { return color; }
    public void setTextSize(int unit, float size) {}
    public void setGravity(int g) {}
    public void setLineSpacing(float add, float mult) {}
    public void setTypeface(Typeface t) {}
    public void setAllCaps(boolean b) {}
}
