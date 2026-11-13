package android.content.pm;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
public class PackageManager {
  public static class NameNotFoundException extends Exception {}
  public static final long MATCH_ARCHIVED_PACKAGES = 1L << 32;
  public static final class ApplicationInfoFlags {
    final long value;
    private ApplicationInfoFlags(long value) { this.value = value; }
    public static ApplicationInfoFlags of(long value) { return new ApplicationInfoFlags(value); }
  }
  /** package -> installer; an absent package answers null (a sideload). */
  public final Map<String, String> installer = new HashMap<>();
  /** What getApplicationInfo answers for: an installed package, and an archived one only when asked for it. */
  public final Set<String> installed = new HashSet<>();
  public final Set<String> archived = new HashSet<>();
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
  public ApplicationInfo getApplicationInfo(String p, int flags) throws NameNotFoundException {
    if (installed.contains(p)) return new ApplicationInfo();
    throw new NameNotFoundException();
  }
  public ApplicationInfo getApplicationInfo(String p, ApplicationInfoFlags flags) throws NameNotFoundException {
    if (installed.contains(p)) return new ApplicationInfo();
    if ((flags.value & MATCH_ARCHIVED_PACKAGES) != 0 && archived.contains(p)) return new ApplicationInfo();
    throw new NameNotFoundException();
  }
}
