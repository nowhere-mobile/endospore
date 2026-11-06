package android.widget;

import android.text.Editable;
import android.text.TextWatcher;
import java.util.ArrayList;

/** Stub for the prep harness (NWP-20261113-22). setText notifies the watchers as the platform's TextView does: after
 *  the text is set, by index over the list with its size taken first. Every setText is counted. */
public class TextView extends android.view.View {
    private CharSequence text = "";
    private final ArrayList<TextWatcher> listeners = new ArrayList<>();
    public int textWrites;

    public void setText(CharSequence t) {
        CharSequence old = text;
        text = t == null ? "" : t;
        textWrites++;
        final ArrayList<TextWatcher> list = listeners;
        final int count = list.size();
        for (int i = 0; i < count; i++) list.get(i).beforeTextChanged(old, 0, old.length(), text.length());
        for (int i = 0; i < count; i++) list.get(i).onTextChanged(text, 0, old.length(), text.length());
        final Editable e = new Ed(text.toString());
        for (int i = 0; i < count; i++) list.get(i).afterTextChanged(e);
    }

    public CharSequence getText() { return text; }
    public void setTextColor(int c) {}
    public void addTextChangedListener(TextWatcher w) { listeners.add(w); }
    public void removeTextChangedListener(TextWatcher w) { listeners.remove(w); }
    public int watchers() { return listeners.size(); }

    private static final class Ed implements Editable {
        private final String s;
        Ed(String s) { this.s = s; }
        @Override public int length() { return s.length(); }
        @Override public char charAt(int i) { return s.charAt(i); }
        @Override public CharSequence subSequence(int a, int b) { return s.substring(a, b); }
        @Override public String toString() { return s; }
    }
}
