package android.net;

public class ConnectivityManager {
    public Network active;
    public NetworkCapabilities caps;
    public Network getActiveNetwork() { return active; }
    public NetworkCapabilities getNetworkCapabilities(Network n) { return caps; }
}
