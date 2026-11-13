package android.graphics;
public class Paint {
    public static final int ANTI_ALIAS_FLAG = 1;
    public enum Style { FILL, STROKE }
    public enum Cap { BUTT, ROUND }
    public enum Join { MITER, ROUND }
    public enum Align { LEFT, CENTER }
    private int color;
    private float textSize = 1f;
    public Paint() {}
    public Paint(int flags) {}
    public void setStyle(Style s) {}
    public void setStrokeCap(Cap c) {}
    public void setStrokeJoin(Join j) {}
    public void setStrokeWidth(float w) {}
    public void setColor(int c) { color = c; }
    public int getColor() { return color; }
    public void setTextAlign(Align a) {}
    public void setTextSize(float s) { textSize = s; }
    public float measureText(String t) { return t.length() * textSize * 0.5f; }
}
