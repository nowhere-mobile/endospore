package android.widget;

/** Test stub: holds the text, and setText replaces it. */
public class EditText {
    private CharSequence text = "";
    public void setText(CharSequence t) { text = t == null ? "" : t; }
    public int length() { return text.length(); }
    public CharSequence getText() { return text; }
}
