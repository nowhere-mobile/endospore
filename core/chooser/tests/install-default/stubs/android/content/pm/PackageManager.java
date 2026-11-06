package android.content.pm;
import java.util.HashMap;
import java.util.Map;
public class PackageManager {
  public static class NameNotFoundException extends Exception {}
  /** package -> installer; an absent package answers null (a sideload). */
  public final Map<String, String> installer = new HashMap<>();
  public boolean throwOnSourceInfo;
  public int sourceInfoCalls, legacyCalls;
  public InstallSourceInfo getInstallSourceInfo(String p) throws NameNotFoundException {
    sourceInfoCalls++;
    if (throwOnSourceInfo) throw new NameNotFoundException();
    return new InstallSourceInfo(installer.get(p));
  }
  public String getInstallerPackageName(String p) {
    legacyCalls++;
    return installer.get(p);
  }
}
