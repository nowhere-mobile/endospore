package android.content.res;
public class ColorStateList {
    private final int color;
    private ColorStateList(int c) { color = c; }
    public static ColorStateList valueOf(int c) { return new ColorStateList(c); }
    public int getDefaultColor() { return color; }
}
