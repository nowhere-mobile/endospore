package android.content;

/** Test stub: the one thing the lifted record writers ask a Context for is its files dir. */
public class Context {
    private final java.io.File filesDir;
    public Context(java.io.File filesDir) { this.filesDir = filesDir; }
    public java.io.File getFilesDir() { return filesDir; }
}
