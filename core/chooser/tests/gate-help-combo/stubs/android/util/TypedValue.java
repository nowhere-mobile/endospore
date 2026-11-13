package android.util;
public class TypedValue {
    public static final int COMPLEX_UNIT_SP = 2;
    public static float applyDimension(int unit, float v, DisplayMetrics m) { return v * m.scaledDensity; }
}
