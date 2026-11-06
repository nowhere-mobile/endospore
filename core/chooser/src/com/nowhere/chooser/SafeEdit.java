package com.nowhere.chooser;

import android.content.Context;
import android.view.KeyEvent;
import android.widget.EditText;

/** An EditText that never reaches the framework's clipboard code unless it may: only a box built with
 *  {@link #withPaste} offers paste, and only while this app's ClipboardManager is reachable.
 *
 *  <p>WHY THIS EXISTS. Our app has no reachable ClipboardManager, so {@code TextView.canPaste()} throws
 *  {@code NullPointerException: 'boolean android.content.ClipboardManager.hasPrimaryClip()' on a null object
 *  reference} and the PROCESS DIES. Three distinct paths reach it:
 *
 *  <ul>
 *    <li>TOUCH -- a long-press / cursor-handle tap / double-tap runs {@code Editor.startInsertionActionMode},
 *        which builds the paste menu via {@code populateMenuWithItems} -> {@code canPaste()}. Blocking
 *        {@code startActionMode} at the View level kills every one of those before the Editor callback runs.</li>
 *    <li>ACCESSIBILITY -- a screen reader (TalkBack) or a {@code uiautomator dump} traversal never touches the
 *        action mode, but {@code onInitializeAccessibilityNodeInfo()} calls {@code canPaste()} anyway to decide
 *        whether to advertise ACTION_PASTE. That is a SEPARATE crash the action-mode block does not cover (#152),
 *        so swallow it and strip the clipboard actions, and refuse an invoked PASTE so TalkBack's edit menu
 *        cannot reach {@code paste()}/{@code canPaste()} either.</li>
 *    <li>KEYBOARD AND IME -- Ctrl+V, Ctrl+Shift+V, Ctrl+X and Ctrl+C ({@code onKeyShortcut}) and the
 *        KEYCODE_PASTE / CUT / COPY keys ({@code onKeyDown}) reach {@code canPaste()} or the clipboard directly,
 *        and an IME's {@code performContextMenuAction} calls {@code onTextContextMenuItem(android.R.id.paste)}
 *        -> {@code paste()}. All three are refused before super (NWP-20261114-21). This path is inferred from
 *        AOSP source, not seen on a device.</li>
 *  </ul>
 *
 *  <p>HISTORY. First written inline in {@code ChooserActivity.field()} for the kiosk gate, where the crash drops
 *  the gate to launcher3/Recents -- proven user-reachable 2026-07-17 by a bare long-press. It was NOT applied to
 *  the Profile app, and on 2026-08-11 a long-press on "Report an issue -> What went wrong?" crashed the Profile
 *  the same way, in the ROAMED user (crash 13:08:40, user 12). That is worth noting precisely: the gate comment
 *  attributed the null ClipboardManager to the confined gate on user 0, but the roamed-user crash shows the
 *  service is unreachable for this app GENERALLY. Any EditText we add anywhere is exposed, which is why this
 *  lives in one shared class rather than being copied to a second call site.
 *
 *  <p>WHAT THIS COSTS. Paste is impossible in a plain SafeEdit, which is intended at the gate. Since
 *  NWP-20261114-21 (Q041) {@link #withPaste} offers paste in the Profile app's report and claim-code boxes only,
 *  and only while {@code getSystemService(ClipboardManager.class)} is non-null, checked at each call and never
 *  stored. An image without the {@code clipboard_service} find for {@code nowhere_chooser} (the follow-up grant
 *  in nowhere.te) returns null there, so those two boxes stay paste-free and crash-free. The gate's fields never
 *  use withPaste.
 */
public class SafeEdit extends EditText {

    private final boolean pasteWanted;

    public SafeEdit(Context c) {
        this(c, false);
    }

    private SafeEdit(Context c, boolean pasteWanted) {
        super(c);
        this.pasteWanted = pasteWanted;
        setLongClickable(false); // skip the long-press haptic/selection attempt outright
    }

    /** A box that offers paste while the clipboard is reachable: the report and claim-code boxes only (Q041). */
    static SafeEdit withPaste(Context c) {
        SafeEdit e = new SafeEdit(c, true);
        e.setLongClickable(true); // startActionMode stays the gate
        return e;
    }

    static boolean pasteAllowed(boolean pasteWanted, boolean clipboardReachable) {
        return pasteWanted && clipboardReachable;
    }

    private boolean allowed() { return pasteAllowed(pasteWanted, clipboardReachable()); }

    // A denied service_manager find makes getSystemService return null. Asked at each call, never cached.
    private boolean clipboardReachable() {
        try {
            return getContext().getSystemService(android.content.ClipboardManager.class) != null;
        } catch (Throwable t) {
            return false;
        }
    }

    @Override public android.view.ActionMode startActionMode(android.view.ActionMode.Callback cb) {
        return allowed() ? super.startActionMode(cb) : null;
    }

    @Override public android.view.ActionMode startActionMode(android.view.ActionMode.Callback cb, int type) {
        return allowed() ? super.startActionMode(cb, type) : null;
    }

    @Override public void onInitializeAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeInfo info) {
        try { super.onInitializeAccessibilityNodeInfo(info); } catch (Throwable ignore) {}
        if (allowed()) return;
        try {
            info.removeAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_PASTE);
            info.removeAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_CUT);
            info.removeAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_COPY);
        } catch (Throwable ignore) {}
    }

    @Override public boolean performAccessibilityAction(int action, android.os.Bundle args) {
        if (action == android.view.accessibility.AccessibilityNodeInfo.ACTION_PASTE && !allowed()) return false;
        try { return super.performAccessibilityAction(action, args); } catch (Throwable t) { return false; }
    }

    // The key code or id is tested first, so ordinary typing never asks for the clipboard service.
    @Override public boolean onKeyShortcut(int keyCode, KeyEvent e) {
        if ((keyCode == KeyEvent.KEYCODE_V || keyCode == KeyEvent.KEYCODE_X || keyCode == KeyEvent.KEYCODE_C)
                && e != null && e.isCtrlPressed() && !allowed()) return true; // Ctrl (+Shift) + V, X, C: consumed
        return super.onKeyShortcut(keyCode, e);
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent e) {
        if ((keyCode == KeyEvent.KEYCODE_PASTE || keyCode == KeyEvent.KEYCODE_CUT || keyCode == KeyEvent.KEYCODE_COPY)
                && !allowed()) return true;
        return super.onKeyDown(keyCode, e);
    }

    @Override public boolean onTextContextMenuItem(int id) {
        if ((id == android.R.id.paste || id == android.R.id.pasteAsPlainText
                || id == android.R.id.cut || id == android.R.id.copy) && !allowed()) return false;
        return super.onTextContextMenuItem(id);
    }
}
