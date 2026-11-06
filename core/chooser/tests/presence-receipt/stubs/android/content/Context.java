package android.content;

/** Test stub: the lifted receipt members ask a Context for its files dir. The user serial is a field here, because
 *  run.sh stubs seenStamp(ctx) as stampFor(ctx.serial): -1 stands for a getSerialNumberForUser that threw. */
public class Context {
    private final java.io.File filesDir;
    public long serial;
    public Context(java.io.File filesDir, long serial) { this.filesDir = filesDir; this.serial = serial; }
    public java.io.File getFilesDir() { return filesDir; }
}
