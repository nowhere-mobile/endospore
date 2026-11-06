package android.net;

/** Test stub: only what DaemonSocket.connect passes to LocalSocket.connect. */
public class LocalSocketAddress {
    public enum Namespace { ABSTRACT, RESERVED, FILESYSTEM }

    private final String name;
    private final Namespace namespace;

    public LocalSocketAddress(String name, Namespace namespace) {
        this.name = name;
        this.namespace = namespace;
    }

    public String getName() { return name; }
    public Namespace getNamespace() { return namespace; }
}
