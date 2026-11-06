package android.content.pm;
public final class InstallSourceInfo {
  public final String installing;
  public InstallSourceInfo(String installing) { this.installing = installing; }
  public String getInstallingPackageName() { return installing; }
}
