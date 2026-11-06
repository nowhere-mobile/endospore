package android.os;
import java.util.HashSet;
import java.util.Set;
public class Bundle {
  public final Set<String> keys = new HashSet<>();
  public boolean containsKey(String k) { return keys.contains(k); }
}
