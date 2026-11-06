package android.util;

/** Test stand-in for android.util.Base64: the two calls TelArrival makes, over java.util.Base64. */
public final class Base64 {
    public static final int NO_WRAP = 2;

    private Base64() {}

    public static String encodeToString(byte[] in, int flags) {
        return java.util.Base64.getEncoder().encodeToString(in);
    }

    /** Throws on input that is not base64, as Android's does. */
    public static byte[] decode(String s, int flags) {
        return java.util.Base64.getDecoder().decode(s);
    }
}
