package android.content.pm;
import java.util.HashMap;
import java.util.Map;
public class PackageManager {
  public static final int GET_META_DATA = 128;
  public static class NameNotFoundException extends Exception {}
  /** package -> the ApplicationInfo it answers; a package not in the map throws NameNotFoundException. */
  public final Map<String, ApplicationInfo> infos = new HashMap<>();
  public ApplicationInfo getApplicationInfo(String p, int flags) throws NameNotFoundException {
    if (flags != GET_META_DATA || !infos.containsKey(p)) throw new NameNotFoundException();
    return infos.get(p);
  }
}
