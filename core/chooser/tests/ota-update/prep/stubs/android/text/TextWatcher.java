package android.text;

/** Stub for the prep harness (NWP-20261113-22): the platform interface's three callbacks. */
public interface TextWatcher {
    void beforeTextChanged(CharSequence s, int start, int count, int after);
    void onTextChanged(CharSequence s, int start, int before, int count);
    void afterTextChanged(Editable s);
}
