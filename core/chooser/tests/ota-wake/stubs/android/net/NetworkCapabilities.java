package android.net;

public class NetworkCapabilities {
    public static final int NET_CAPABILITY_VALIDATED = 16;
    public static final int NET_CAPABILITY_INTERNET = 12;
    public final java.util.Set<Integer> caps = new java.util.HashSet<>();
    public boolean hasCapability(int c) { return caps.contains(c); }
}
