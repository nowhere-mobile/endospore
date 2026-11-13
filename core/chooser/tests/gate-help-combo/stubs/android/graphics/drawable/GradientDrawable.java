package android.graphics.drawable;
public class GradientDrawable extends Drawable {
    public static final int OVAL = 1;
    public int fill, stroke;
    public boolean hasStroke;
    public void setShape(int s) {}
    public void setColor(int c) { fill = c; }
    public void setCornerRadius(float r) {}
    public void setStroke(int w, int c) { stroke = c; hasStroke = true; }
}
