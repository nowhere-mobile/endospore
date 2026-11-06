package android.content;
public class Context {
  public android.content.pm.PackageManager pm;
  public Context(android.content.pm.PackageManager pm) { this.pm = pm; }
  public android.content.pm.PackageManager getPackageManager() { return pm; }
}
