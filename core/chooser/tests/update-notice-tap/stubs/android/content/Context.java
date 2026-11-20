package android.content;

/** NWP-20261208-32 stub: a context of one user in one package. getApplicationContext() returns a NEW object each call,
 *  so a PendingIntent made on it fails U4's identity check. */
public class Context {
    public final int userId;
    public final String pkg;

    public Context(int userId, String pkg) { this.userId = userId; this.pkg = pkg; }

    public String getPackageName() { return pkg; }

    public Context getApplicationContext() { return new Context(userId, pkg); }
}
