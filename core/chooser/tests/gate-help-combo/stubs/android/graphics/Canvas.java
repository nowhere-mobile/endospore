package android.graphics;
import java.util.ArrayList;
import java.util.List;
/** Records every colour drawn and every string drawn. */
public class Canvas {
    public final List<Integer> colors = new ArrayList<>();
    public final List<String> texts = new ArrayList<>();
    public void drawRoundRect(RectF r, float rx, float ry, Paint p) { colors.add(p.getColor()); }
    public void drawLine(float a, float b, float c, float d, Paint p) { colors.add(p.getColor()); }
    public void drawCircle(float x, float y, float r, Paint p) { colors.add(p.getColor()); }
    public void drawArc(RectF o, float s, float e, boolean c, Paint p) { colors.add(p.getColor()); }
    public void drawPath(Path a, Paint p) { colors.add(p.getColor()); }
    public void drawText(String t, float x, float y, Paint p) { colors.add(p.getColor()); texts.add(t); }
}
