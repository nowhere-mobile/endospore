#!/usr/bin/env bash
# test-app-filter-java.sh [--mutate] -- the "Your apps" search and the A-to-Z order of its other rows, run under javac
# (NWP-20261016-48), and its rows with no launcher icon with their Off / Keep installed picker (NWP-20261111-13).
#
# NO ICON (NWP-20261111-13, docs/product-decisions.md Q140, DECIDED 2026-10-20). An installed app with no launcher icon
# (a keyboard, an icon pack, a plugin, a widget-only app) had no row unless its store default kept it, so it could not
# be kept and was gone at the next sign-in. AppFilter.launcherless picks those rows from this user's installed apps
# (not self, gms, gsf, a system or updated system app, or an app with no APK), the list thread adds them through the
# launcher pass's own `seen` before the keep-set lock, and AppFilter.keepModes gives their picker Off and Keep
# installed only. P_LL, P_NOICON, P_PICK, P_PICK2 and P_MODEWORDS pin the call sites; N1-N6 must be convicted.
#
# WHY THIS IS COMMITTED. Chester, 2026-10-16: "your apps - can we add a filter on top? I've about 50 apps and getting
# harder to find the app I am looking for". He accepted (docs/product-decisions.md, 2026-10-16): a search pinned at the
# top that filters the list live by label and package, ignoring case and accents; reordering paused while a search is
# active; the search cleared when you leave; the apps after the kept ones listed A to Z (the kept ones keep the order
# they were dragged into, the install order); no mode chips. The rules are in
# core/chooser/src/com/nowhere/chooser/AppFilter.java (pure Java), compiled as it stands with
# core/chooser/tests/app-filter/AppFilterCases.java.
#
# THE CALL SITES ARE PINNED, AS BLOCKS. A correct rule called wrongly is the same bug: a field built as a bare
# EditText (it dies on a long-press in the roamed user, SafeEdit), a field that takes the row drag (a release on it
# types the package name in), a search that is not re-applied when the rows land or after a mode change, handles that
# stay hidden after Clear, a head that scrolls away. The pins hold each wiring block byte for byte in
# ProfileActivity.java, and each call-site mutation at the end must be convicted by one, or by an absence check.
# EVERY BLOCK STARTS WHERE NO GUARD CAN GO: at a declaration, a method's signature, or the brace that ends the statement
# before it. So an `if (false)` line above a pinned statement, a comment of a pinned line, or a move of a statement in a
# block breaks its pin -- a guard above the block's first line would have to guard a declaration or a brace, which Java
# refuses. A comment or guard that ALSO takes in the code around a block is not seen by any pin: a large enough wrap
# always defeats a substring pin (wrapping appKeepRow's handle setup together with P_HANDLE still compiles), and the
# image build and the device step are what see that (this suite compiles AppFilter, not ProfileActivity). What no pin can
# see is a statement added after a block that undoes it: for the drag refusal, which one more setOnDragListener would
# undo, a check counts the field's listeners in showYourApps (one, never two).
# The absence checks (no bare EditText, no log line, no file write, no second drag listener) are scoped to
# showYourApps -- the file has an older bare EditText elsewhere -- and each carries a control that must match, so a
# method that moved cannot read as clean. applyYourAppsFilter needs none: P_APPLY pins it whole. A pin would hide a
# broken absence check, so each check has mutants on showYourApps lines no pin covers, credited only when that check is
# the ONE failure the suite reports (mut's fourth argument): if absent_in or second_in stopped detecting, they would
# survive.
#
# IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it. The version
# is printed first so the log proves which compiler ran.
#
#   bash test-app-filter-java.sh            # the cases + the pins
#   bash test-app-filter-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/AppFilter.java"
PRO="$DIR/ProfileActivity.java"
RUN="$root/core/chooser/tests/app-filter/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$PRO" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# ---- the pinned blocks (quoted heredocs: every character below is literal source text) ----
# Each starts at a declaration, a method's signature or the brace that ends the statement before it (the header says
# why); a block added here starts the same way, or an `if (false)` line above it passes.
IFS= read -r -d '' P_HEAD <<'EOF'
        final LinearLayout head = menuScreen("Your apps", "keep an app and it comes back on any nowhere phone");
        head.setPadding(dp(22), dp(44), dp(22), dp(4));
        final LinearLayout ll = new LinearLayout(this);
EOF
IFS= read -r -d '' P_FIELD <<'EOF'
        final EditText search = textField("Search your apps");
        search.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_FILTER
                | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        search.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
                | android.view.inputmethod.EditorInfo.IME_FLAG_NO_FULLSCREEN
                | android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI
                | android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        // The list filters live, so the keyboard's search key only puts the keyboard away.
        search.setOnEditorActionListener((v, action, ev) -> {
            if (action != android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH) return false;
            hideKeyboard(true);
            return true;
        });
        search.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
            @Override public void onViewAttachedToWindow(View v) {}
            // Leaving the screen takes the field away; the keyboard goes with it. No clearFocus while it comes down.
            @Override public void onViewDetachedFromWindow(View v) { hideKeyboard(false); }
        });
        // The list's row drag must never land here. The field sits just above the list's edge-scroll zone, and an
        // editable TextView takes a drag on its own: it takes focus as the drag enters, and a release types the drag's
        // text -- the row's package name -- in, filtering the list to that one app. A listener that returns true takes
        // every drag event, so TextView.onDragEvent never runs; one that returns false falls through to it. The list
        // still gets DRAG_ENDED and writes the order.
        search.setOnDragListener((v, e) -> true);
EOF
IFS= read -r -d '' P_CLEAR <<'EOF'
        final TextView clear = new TextView(this);
        clear.setText("Clear");
        clear.setTextColor(ACCENT);
        clear.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        clear.setPadding(dp(14), dp(12), dp(4), dp(12));
        clear.setContentDescription("Clear search");
        clear.setVisibility(View.GONE);
        clear.setOnClickListener(v -> search.setText(""));
EOF
IFS= read -r -d '' P_HEADROW <<'EOF'
        final LinearLayout searchRow = new LinearLayout(this);
        searchRow.setOrientation(LinearLayout.HORIZONTAL);
        searchRow.setGravity(Gravity.CENTER_VERTICAL);
        searchRow.addView(search, new LinearLayout.LayoutParams(0, WRAP, 1f));
        searchRow.addView(clear, new LinearLayout.LayoutParams(WRAP, WRAP));
        LinearLayout.LayoutParams srlp = new LinearLayout.LayoutParams(MATCH, WRAP);
        srlp.topMargin = dp(14);
        head.addView(searchRow, srlp);
EOF
IFS= read -r -d '' P_WATCH <<'EOF'
        final TextView count = new TextView(this);
        count.setTextColor(MUTED);
        count.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        count.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        count.setVisibility(View.GONE);
        LinearLayout.LayoutParams cnlp = new LinearLayout.LayoutParams(MATCH, WRAP);
        cnlp.topMargin = dp(6);
        head.addView(count, cnlp);
        search.addTextChangedListener(new android.text.TextWatcher() {
            @Override public void afterTextChanged(android.text.Editable s) {
                clear.setVisibility(s.length() > 0 ? View.VISIBLE : View.GONE);
                if (!applyYourAppsFilter(list, s, count)) return;
                // Searching: bring the list's top under the head, so the matches fill the space above the keyboard
                // rather than the note and the settings rows.
                if (ll.getParent() instanceof android.widget.ScrollView) {
                    final android.widget.ScrollView sv = (android.widget.ScrollView) ll.getParent();
                    sv.post(() -> sv.scrollTo(0, list.getTop()));
                }
            }
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) {}
        });
EOF
IFS= read -r -d '' P_PRESENT <<'EOF'
        final android.widget.ProgressBar spin = new android.widget.ProgressBar(this);
        spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(ACCENT)); // NWP-20261007-13
        LinearLayout.LayoutParams splp = new LinearLayout.LayoutParams(WRAP, WRAP);
        splp.gravity = Gravity.CENTER; splp.topMargin = dp(20);
        ll.addView(spin, splp);

        // #74a: entered from Preferences (showPreferences :1087/:1090), not the Profile hub.
        finishMenuScreen(ll, this::showPreferences, head); // present now; fill the list off-thread
EOF
IFS= read -r -d '' P_FINISH <<'EOF'
    private void finishMenuScreen(LinearLayout ll, Runnable onBack, LinearLayout head) {
        TextView back = new TextView(this);
        back.setText("Back");
        back.setTextColor(ACCENT);
        back.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        back.setGravity(Gravity.CENTER);
        back.setPadding(dp(8), dp(22), dp(8), dp(8));
        ll.addView(back, new LinearLayout.LayoutParams(MATCH, WRAP));
        back.setOnClickListener(v -> onBack.run());
        if (head == null) presentMenuScreen(ll);
        else presentMenuScreen(head, ll);
    }
EOF
IFS= read -r -d '' P_PINNED <<'EOF'
    private void presentMenuScreen(LinearLayout head, LinearLayout ll) {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        root.addView(head, new LinearLayout.LayoutParams(MATCH, WRAP));
        android.widget.ScrollView sc = new android.widget.ScrollView(this);
        sc.setBackgroundColor(BG);
        sc.addView(ll);
        root.addView(sc, new LinearLayout.LayoutParams(MATCH, 0, 1f));
        setContentView(root);
    }
EOF
IFS= read -r -d '' P_AZ <<'EOF'
                java.util.List<String> sorted = KeepOrder.keptFirst(pkgs, keptNow);
                pkgs.clear();
                pkgs.addAll(sorted);
                // NWP-20261016-48: the rows after the kept block, A to Z by the label each row shows (the kept block keeps
                // its dragged order, the install order). keptLabel is PackageManager work, so it runs here, on the list
                // thread, as the Storage screen's label prefetch does.
                final java.util.Map<String, String> otherLabels = new java.util.HashMap<>();
                for (String p : pkgs) if (!keptNow.contains(p)) otherLabels.put(p, String.valueOf(keptLabel(p)));
                java.util.List<String> listed = AppFilter.otherRowsAtoZ(pkgs, keptNow, otherLabels);
                pkgs.clear();
                pkgs.addAll(listed);
                // NWP-20261012-06: each kept row's "Wake for notifications" state, here and not per row on the UI
                // thread -- the messaging rule is PackageManager work. A row kept later this visit asks on its own.
                keepRowWake.clear(); // the map outlives the visit: a stale entry would paint an old default
                for (String p : pkgs) if (keptNow.contains(p)) keepRowWake.put(p, UnarchiveService.wakeOnRestore(this, p));
            } catch (Throwable ignore) {}
EOF
IFS= read -r -d '' P_EMPTY <<'EOF'
            } catch (Throwable ignore) {}
            // NWP-20260826-11: resolve the Keystore census HERE, on the background thread and once for the
            // whole screen. It is a socket round-trip to the daemon plus a worker hop, so doing it per row --
            // or on the main thread -- would be the same mistake as the gate ANR in NWP-20260826-10, on a
            // screen that already takes a visible moment to build.
            runOnUiThread(() -> {
                ll.removeView(spin);
                if (pkgs.isEmpty()) {
                    TextView empty = new TextView(this);
                    empty.setText("No apps to keep yet — apps you install will show up here.");
                    empty.setTextColor(MUTED);
                    empty.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
                    empty.setPadding(dp(4), dp(20), dp(4), dp(4));
                    list.addView(empty);
                    if (search.hasFocus()) hideKeyboard(true); // NWP-20261016-48: nothing to search
                    searchRow.setVisibility(View.GONE);
                    count.setVisibility(View.GONE);
                    return;
                }
EOF
IFS= read -r -d '' P_FILL <<'EOF'
                final Runnable onRowChange = () -> {
                    updateSummary.run();
                    // Only when drained: the enqueue call runs before setAppMode has written the keep-set.
                    if (MODE_PENDING.get() == 0) refreshPendingRow(ll, summary, pendingRowView, pendingShown, pendingTicket);
                    applyYourAppsFilter(list, search.getText(), count);
                };
                keepRowPaints.clear(); // NWP-20260821-11: drop the previous build's runnables with its views
                keepRowSizePaints.clear(); // NWP-20261119-30: and their size repaints
                list.setOnDragListener(keepOrderDrag(list));
                for (String p : pkgs)
                    list.addView(appKeepRow(p, sizes.get(p), Boolean.TRUE.equals(side.get(p)), onRowChange),
                            new LinearLayout.LayoutParams(MATCH, WRAP));
                applyYourAppsFilter(list, search.getText(), count); // NWP-20261016-48: a query typed while the list loaded
                // NWP-20261117-40: the end of a sweep re-measures the sizes, redraws the summary line and recounts the
                // install row. Before, only a drained mode change did, so after "Install pending apps now" the open
                // screen kept the waiting row, "Started" and "~0 B on this device" (lynx 2026102901).
                if (ll.isAttachedToWindow()) {
                    final android.content.BroadcastReceiver sweepDone = new android.content.BroadcastReceiver() {
                        @Override public void onReceive(android.content.Context c, Intent i) {
                            if (!ll.isAttachedToWindow()) return;
                            new Thread(() -> {
                                final java.util.Map<String, Long> fresh = new java.util.HashMap<>();
                                for (String p : pkgs) {
                                    try { fresh.put(p, apkSize(pm.getApplicationInfo(p, 0))); }
                                    catch (Throwable ignore) {} // archived or gone: it keeps its old size
                                }
                                runOnUiThread(() -> {
                                    if (!ll.isAttachedToWindow()) return; // sweep done: the user left Your apps
                                    sizes.putAll(fresh); // UI thread only, as updateSummary reads it
                                    updateSummary.run();
                                    // NWP-20261119-30: each row redraws its own size line, and the install row is
                                    // rebuilt even at an unchanged count, so a sweep that leaves apps pending offers
                                    // "Install" again instead of a dead "Started".
                                    for (java.util.function.Consumer<java.util.Map<String, Long>> r : new java.util.ArrayList<>(keepRowSizePaints)) {
                                        try { r.accept(sizes); } catch (Throwable ignore) {}
                                    }
                                    if (MODE_PENDING.get() == 0) refreshPendingRow(ll, summary, pendingRowView, pendingShown, pendingTicket, true);
                                });
                            }, "nowhere-sweepdone").start();
                        }
                    };
                    registerReceiver(sweepDone, new android.content.IntentFilter(UnarchiveService.ACTION_SWEEP_DONE),
                            android.content.Context.RECEIVER_NOT_EXPORTED);
                    ll.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
                        @Override public void onViewAttachedToWindow(View v) {}
                        @Override public void onViewDetachedFromWindow(View v) {
                            try { unregisterReceiver(sweepDone); } catch (Throwable ignore) {}
                        }
                    });
                }
            });
EOF
IFS= read -r -d '' P_KEY <<'EOF'
        final CharSequence rowLabel = keptLabel(pkg);
        tag.key = AppFilter.key(rowLabel, pkg); // NWP-20261016-48: what the search matches, the label this row shows
EOF
IFS= read -r -d '' P_HANDLE <<'EOF'
        });
        row.addView(handle, new LinearLayout.LayoutParams(WRAP, WRAP));
        tag.handle = handle; // NWP-20261016-48: applyYourAppsFilter hides it while a search is active
EOF
IFS= read -r -d '' P_SHOWS <<'EOF'
        final ModePreview orderWake = m -> {
            tag.kept = m != null;
            handle.setVisibility(AppFilter.reorderable(m != null, tag.searching) ? View.VISIBLE : View.INVISIBLE);
EOF
IFS= read -r -d '' P_APPLY <<'EOF'
    private boolean applyYourAppsFilter(LinearLayout list, CharSequence q, TextView count) {
        String[] terms = AppFilter.terms(q);
        boolean searching = terms.length > 0;
        int shown = 0, total = 0;
        boolean keptShown = false;
        for (int i = 0; i < list.getChildCount(); i++) {
            View row = list.getChildAt(i);
            if (!(row.getTag() instanceof KeepRowTag)) continue;
            KeepRowTag t = (KeepRowTag) row.getTag();
            total++;
            t.searching = searching;
            boolean hit = AppFilter.matches(terms, t.key);
            row.setVisibility(hit ? View.VISIBLE : View.GONE);
            if (hit) { shown++; if (t.kept) keptShown = true; }
            if (t.handle != null)
                t.handle.setVisibility(AppFilter.reorderable(t.kept, searching) ? View.VISIBLE : View.INVISIBLE);
        }
        String line = AppFilter.countLine(q, shown, total, keptShown);
        count.setText(line == null ? "" : line);
        count.setVisibility(line == null ? View.GONE : View.VISIBLE);
        return searching;
    }
EOF
IFS= read -r -d '' P_HIDE <<'EOF'
    private void hideKeyboard(boolean clear) {
        try {
            android.view.inputmethod.InputMethodManager imm =
                    (android.view.inputmethod.InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            View f = getCurrentFocus();
            android.os.IBinder tok = (f != null) ? f.getWindowToken()
                    : getWindow().getDecorView().getWindowToken();
            if (imm != null && tok != null) imm.hideSoftInputFromWindow(tok, 0);
            if (clear && f != null) f.clearFocus();
        } catch (Throwable ignore) {
        }
    }
EOF
IFS= read -r -d '' P_LBLREAD <<'EOF'
    private synchronized java.util.HashMap<String,String> labelCache() {
EOF
IFS= read -r -d '' P_LBLWRITE <<'EOF'
    private synchronized void rememberLabel(String pkg, CharSequence label) {
EOF
IFS= read -r -d '' P_LBLGET <<'EOF'
        String cached;
        synchronized (this) { cached = labelCache().get(pkg); }
EOF

IFS= read -r -d '' P_LL <<'EOF'
                final java.util.List<String[]> installed = new java.util.ArrayList<>();
                try {
                    for (android.content.pm.ApplicationInfo ai : pm.getInstalledApplications(0)) {
                        if (ai == null || ai.packageName == null) continue;
                        installed.add(new String[] { ai.packageName,
                                (ai.flags & android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0 ? "1" : "0",
                                (ai.flags & android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0 ? "1" : "0",
                                ai.sourceDir == null || ai.sourceDir.isEmpty() ? "0" : "1" });
                    }
                } catch (Throwable ignore) {}
                for (String p : AppFilter.launcherless(installed, seen, getPackageName(), GMS_PKG, GSF_PKG)) {
                    if (!seen.add(p)) continue;
                    try {
                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p, 0);
                        pkgs.add(p); sizes.put(p, apkSize(ai)); side.put(p, isSideloaded(pm, p));
                        noIcon.add(p);
                    } catch (Throwable ignore) {}
                }
EOF
IFS= read -r -d '' P_NOICON <<'EOF'
                yourAppsNoIcon = noIcon; // NWP-20261111-13: before any row is painted; read by showKeepModeDialog
                final Runnable updateSummary = () -> {
EOF
IFS= read -r -d '' P_PICK <<'EOF'
    private void showKeepModeDialog(final String pkg, final boolean sideloaded, final Runnable paint,
                                    final ModePreview preview, final Runnable onChange) {
        final String cur = appMode(pkg); // null=off, installed, auto, ondemand
        // NWP-20261111-13 (Q140): an app with no launcher icon (yourAppsNoIcon, from the list build) is offered Off and
        // Keep installed only -- On-demand and Auto rely on an icon placeholder it cannot show. At On-demand or Auto
        // (a store default) no item is checked; picking one replaces it.
        final boolean hasIcon = !yourAppsNoIcon.contains(pkg);
        final java.util.List<String[]> modes = AppFilter.keepModes(hasIcon);
        final CharSequence[] items = new CharSequence[modes.size()];
        int checked = -1;
        for (int i = 0; i < modes.size(); i++) {
            items[i] = modes.get(i)[0];
            if (java.util.Objects.equals(modes.get(i)[1], cur)) checked = i;
        }
        if (checked < 0 && hasIcon) checked = 0; // as before: a mode word it does not know reads as Off
EOF
IFS= read -r -d '' P_PICK2 <<'EOF'
                .setSingleChoiceItems(items, checked, (d, which) -> {
                    d.dismiss();
                    applyKeepMode(pkg, modes.get(which)[1], sideloaded, paint, preview, onChange);
EOF
IFS= read -r -d '' P_MODEWORDS <<'EOF'
    static final String MODE_INSTALLED = "installed";
    static final String MODE_ONDEMAND  = "ondemand";
    static final String MODE_AUTO      = "auto";
EOF
# pinned <file> <label> <block>: the block must appear verbatim in the file.
pinned() {
  local body; body=$(cat "$1")
  [[ "$body" == *"$3"* ]] && return 0
  echo "  PIN   $2 -- the block is gone or changed in $(basename "$1")" >&2
  return 1
}
# method <file> <signature>: the method whose declaration line starts with <signature>, through the first line that is
# exactly four spaces and a closing brace (members are indented four, their bodies eight). Empty when it is not there.
method() { SIG="$2" awk 'index($0, ENVIRON["SIG"]) == 1 { on = 1 } on { print } on && $0 == "    }" { exit }' "$1"; }
# absent_in <file> <signature> <label> <text> <control>: <text> must not appear in the method, and <control> (which must)
# proves the method was found and read.
absent_in() {
  local body; body=$(method "$1" "$2")
  if [[ "$body" != *"$5"* ]]; then
    echo "  CTRL  $3 -- the method is gone or its control is missing, so the check proves nothing" >&2; return 1
  fi
  [[ "$body" == *"$4"* ]] || return 0
  echo "  BACK  $3 -- found in $(basename "$1")" >&2
  return 1
}
# second_in <file> <signature> <label> <text> <control>: <text> may appear once in the method, never twice. A pin holds
# the first call where it is; a second one added after the pinned block would undo it with every pin intact. Whether
# the first is there at all is its pin's question, not this check's.
second_in() {
  local body rest n; body=$(method "$1" "$2")
  if [[ "$body" != *"$5"* ]]; then
    echo "  CTRL  $3 -- the method is gone or its control is missing, so the check proves nothing" >&2; return 1
  fi
  rest=${body//"$4"/}
  n=$(( (${#body} - ${#rest}) / ${#4} ))
  [ "$n" -le 1 ] && return 0
  echo "  BACK  $3 -- $n of them in $(basename "$1")" >&2
  return 1
}

SYA='    private void showYourApps() {'

# suite <AppFilter> <ProfileActivity> -> 0 pass; 1 a case or a pin failed (both are behaviour here: a pin is how a
# call-site mutant is convicted); 3 the class or the cases did not compile.
suite() {
  local o="$1" p="$2" bad=0
  pinned "$p" "the title and the search are a head of their own"                      "$P_HEAD"      || bad=1
  pinned "$p" "the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" "$P_FIELD" || bad=1
  pinned "$p" "Clear empties the field, and shows only with text"                      "$P_CLEAR"     || bad=1
  pinned "$p" "the field and Clear sit in the head"                                    "$P_HEADROW"   || bad=1
  pinned "$p" "the count line sits in the head, hidden and announced, and every keystroke re-applies the search and brings the matches up" "$P_WATCH" || bad=1
  pinned "$p" "Your apps is presented with its head pinned"                            "$P_PRESENT"   || bad=1
  pinned "$p" "finishMenuScreen adds Back and presents a head outside the scroll"      "$P_FINISH"    || bad=1
  pinned "$p" "the head is above the ScrollView, not in it"                            "$P_PINNED"    || bad=1
  pinned "$p" "the other rows go A to Z after keptFirst, on the list thread"           "$P_AZ"        || bad=1
  pinned "$p" "with no apps the search is hidden"                                      "$P_EMPTY"     || bad=1
  pinned "$p" "a mode change re-applies the search, the rows take it, and a query typed while loading applies" "$P_FILL" || bad=1
  pinned "$p" "each row is searched by the label it shows and its package"             "$P_KEY"       || bad=1
  pinned "$p" "each row hands its handle to the filter"                                "$P_HANDLE"    || bad=1
  pinned "$p" "a repaint keeps the handle hidden under a search"                       "$P_SHOWS"     || bad=1
  pinned "$p" "the filter hides, never removes, and pauses and restores the handles"   "$P_APPLY"     || bad=1
  pinned "$p" "hideKeyboard finds the field, hides, and drops focus only when asked"   "$P_HIDE"      || bad=1
  pinned "$p" "the label cache is read under the lock"                                 "$P_LBLREAD"   || bad=1
  pinned "$p" "... written under it"                                                   "$P_LBLWRITE"  || bad=1
  pinned "$p" "... and looked up under it"                                             "$P_LBLGET"    || bad=1
  pinned "$p" "the launcher-less pass lists this user's icon-less apps through the shared seen, before the lock" "$P_LL" || bad=1
  pinned "$p" "the icon-less rows reach the picker before any row is painted"          "$P_NOICON"    || bad=1
  pinned "$p" "the picker builds its items and the checked row from keepModes"         "$P_PICK"      || bad=1
  pinned "$p" "... and the chosen mode"                                                "$P_PICK2"     || bad=1
  pinned "$p" "keepModes' mode words are ProfileActivity's"                            "$P_MODEWORDS" || bad=1
  absent_in "$p" "$SYA" "a bare EditText in Your apps"            'new EditText('              'textField("Search your apps")' || bad=1
  absent_in "$p" "$SYA" "a bare qualified EditText in Your apps"  'new android.widget.EditText(' 'textField("Search your apps")' || bad=1
  absent_in "$p" "$SYA" "a log line in Your apps (the query is profile content)" 'Log.'      'textField("Search your apps")' || bad=1
  absent_in "$p" "$SYA" "a file write in Your apps (the files dir roams)"        'getFilesDir' 'textField("Search your apps")' || bad=1
  second_in "$p" "$SYA" "a second drag listener on the field (it would undo the refusal)" 'search.setOnDragListener(' 'textField("Search your apps")' || bad=1
  # No absence check reads applyYourAppsFilter: P_APPLY pins it whole, from its signature to its closing brace, so a log
  # line or a file write added anywhere in it already fails that pin, and a check there could never be the one that fails.
  [ "$bad" = 0 ] || return 1
  bash "$RUN" "$o"
}

echo "== $SRC (+ pins in $(basename "$PRO"))"
suite "$SRC" "$PRO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour, a pin or an absence check: a mutant that does not compile proves nothing)"
# mut <label> <which: O|P> <perl-expr> [<check>]   (O = AppFilter.java, P = ProfileActivity.java)
# With <check> -- a pin's or an absence check's report, kind and label, as the suite prints it ("BACK  a log line in
# Your apps ...") -- the mutant is credited only when that is the one PIN/CTRL/BACK line the suite reports: it proves
# that check, not some other pin that happened to cover the same line.
mut() {
  local d rc err found o="$SRC" p="$PRO" t
  d=$(mktemp -d)
  case "$2" in O) t="$SRC" ;; P) t="$PRO" ;; esac
  local m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in O) o="$m" ;; P) p="$m" ;; esac
  err=$(suite "$o" "$p" 2>&1 >/dev/null); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  if [ -n "${4:-}" ]; then
    found=$(printf '%s\n' "$err" | grep -E '^  (PIN|CTRL|BACK) ' || true)
    if [[ "$found" != "  $4 -- "* ]] || [ "$(printf '%s\n' "$found" | wc -l)" -ne 1 ]; then
      echo "  MISCREDITED $1 -- failed, but not on \"$4\" alone; the suite reported:"
      printf '%s\n' "${found:-    (no check line at all)}" | sed 's/^/      /'
      return 1
    fi
  fi
  echo "  convicted $1"; return 0
}
fails=0
# the rules (\x27 is a quote, \x5c a backslash: the source spells the letters as escapes)
mut "R1 lower-casing dropped"                         O 's/\n            c = Character\.toLowerCase\(c\);//' || fails=$((fails+1))
mut "R2 accents kept"                                 O 's/\n            if \(Character\.getType\(c\) == Character\.NON_SPACING_MARK\) continue;//' || fails=$((fails+1))
mut "R3 sharp s not spelled ss"                       O 's/\n                case 0x00df: b\.append\("ss"\); break;[^\n]*//' || fails=$((fails+1))
mut "R4 ae ligature not spelled ae"                   O 's/\n                case 0x00e6: b\.append\("ae"\); break;[^\n]*//' || fails=$((fails+1))
mut "R5 oe ligature not spelled oe"                   O 's/\n                case 0x0153: b\.append\("oe"\); break;[^\n]*//' || fails=$((fails+1))
mut "R6 slashed o not plain"                          O 's/\n                case 0x00f8: b\.append\(\x27o\x27\); break;[^\n]*//' || fails=$((fails+1))
mut "R7 barred l not plain"                           O 's/\n                case 0x0142: b\.append\(\x27l\x27\); break;[^\n]*//' || fails=$((fails+1))
mut "R8 stroked d not plain"                          O 's/\n                case 0x0111: b\.append\(\x27d\x27\); break;[^\n]*//' || fails=$((fails+1))
mut "R9 dotless i not plain"                          O 's/\n                case 0x0131: b\.append\(\x27i\x27\); break;[^\n]*//' || fails=$((fails+1))
mut "R10 NFD instead of NFKD"                         O 's/Normalizer\.Form\.NFKD/Normalizer.Form.NFD/' || fails=$((fails+1))
mut "R11 white space not collapsed"                   O 's/\{ gap = b\.length\(\) > 0; continue; \}/{ b.append(\x27 \x27); continue; }/' || fails=$((fails+1))
mut "R12 white space kept at the start"               O 's/gap = b\.length\(\) > 0;/gap = true;/' || fails=$((fails+1))
mut "R13 the query is not folded"                     O 's/String f = fold\(q\);/String f = q == null ? "" : q.toString().trim();/' || fails=$((fails+1))
mut "R14 any one term is enough"                      O 's/for \(String t : terms\) if \(!k\.contains\(t\)\) return false;\n        return true;/for (String t : terms) if (k.contains(t)) return true;\n        return terms.length == 0;/' || fails=$((fails+1))
mut "R15 a term must start the key"                   O 's/if \(!k\.contains\(t\)\) return false;/if (!k.startsWith(t)) return false;/' || fails=$((fails+1))
mut "R16 label and package run together"              O 's/return fold\(label\) \+ "\x5cn" \+ fold\(pkg\);/return fold(label) + fold(pkg);/' || fails=$((fails+1))
mut "R17 the package is not searched"                 O 's/return fold\(label\) \+ "\x5cn" \+ fold\(pkg\);/return fold(label) + "\x5cn";/' || fails=$((fails+1))
mut "R18 an empty search matches nothing"             O 's/(        String k = key == null \? "" : key;)/        if (terms.length == 0) return false;\n$1/' || fails=$((fails+1))
mut "R19 a kept row reorders under a search"          O 's/return kept && !searching;/return kept;/' || fails=$((fails+1))
mut "R20 the count shows while the list loads"        O 's/if \(terms\(q\)\.length == 0 \|\| total == 0\) return null;/if (terms(q).length == 0) return null;/' || fails=$((fails+1))
mut "R21 the reorder line shows with no kept match"   O 's/return keptShown \? s \+/return true ? s +/' || fails=$((fails+1))
mut "R22 nothing found does not say bundled apps are not listed" O 's/ Apps that came with the phone, "\n                \+ "and Google Play services, are not listed here\.";/";/' || fails=$((fails+1))
mut "R23 one app is counted as apps"                  O 's/\(total == 1 \? " app" : " apps"\)/" apps"/' || fails=$((fails+1))
mut "S1 the kept block is sorted too"                 O 's/if \(kept\.contains\(p\)\) out\.add\(p\);\n            else rest\.add\(p\);/rest.add(p);/' || fails=$((fails+1))
mut "S2 the other rows are not sorted"                O 's/        rest\.sort\(\(a, b\) -> \{/        if (false) rest.sort((a, b) -> {/' || fails=$((fails+1))
mut "S3 the sort minds case and accents"              O 's/int c = folded\.get\(a\)\.compareTo\(folded\.get\(b\)\);/int c = shown.get(a).compareTo(shown.get(b));/' || fails=$((fails+1))
mut "S4 a tie is not broken by package"               O 's/return c != 0 \? c : a\.compareTo\(b\);/return c;/' || fails=$((fails+1))
mut "S5 a row with no label sorts first"              O 's/if \(l == null \|\| l\.isEmpty\(\)\) l = p;/if (l == null || l.isEmpty()) l = "";/' || fails=$((fails+1))
mut "S6 the other rows are dropped"                   O 's/\n        out\.addAll\(rest\);//' || fails=$((fails+1))
mut "S7 the kept block goes last"                     O 's/        out\.addAll\(rest\);\n        return out;/        rest.addAll(out);\n        return rest;/' || fails=$((fails+1))
# the call sites -- each convicted by a pin, except C14, C15, C29-C31 and C40, which prove the absence checks (C6 also
# fails the checks' control, which it rewrites)
mut "C1 a query typed while loading is not applied"   P 's/\n                applyYourAppsFilter\(list, search\.getText\(\), count\); \/\/ NWP-20261016-48: a query typed while the list loaded//' || fails=$((fails+1))
mut "C2 a keystroke does not filter"                  P 's/if \(!applyYourAppsFilter\(list, s, count\)\) return;/if (s.length() == 0) return;/' || fails=$((fails+1))
mut "C3 a repaint shows the handle under a search"    P 's/handle\.setVisibility\(AppFilter\.reorderable\(m != null, tag\.searching\) \?/handle.setVisibility(m != null ?/' || fails=$((fails+1))
mut "C4 Clear leaves the handles hidden"              P 's/\n            if \(t\.handle != null\)\n                t\.handle\.setVisibility\(AppFilter\.reorderable\(t\.kept, searching\) \? View\.VISIBLE : View\.INVISIBLE\);//' || fails=$((fails+1))
mut "C5 the row never learns a search is active"      P 's/\n            t\.searching = searching;//' || fails=$((fails+1))
mut "C6 the field is a bare EditText"                 P 's/final EditText search = textField\("Search your apps"\);/final EditText search = new android.widget.EditText(this); search.setHint("Search your apps");/' || fails=$((fails+1))
mut "C7 a mode change leaves the search stale"        P 's/Boolean\.TRUE\.equals\(side\.get\(p\)\), onRowChange\)/Boolean.TRUE.equals(side.get(p)), updateSummary)/' || fails=$((fails+1))
mut "C8 the other rows are left in found order"       P 's/                pkgs\.clear\(\);\n                pkgs\.addAll\(listed\);\n//' || fails=$((fails+1))
mut "C9 the head is never shown"                      P 's/finishMenuScreen\(ll, this::showPreferences, head\);/finishMenuScreen(ll, this::showPreferences);/' || fails=$((fails+1))
mut "C10 the head scrolls away with the list"         P 's/        root\.addView\(head, new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);\n(.*\n.*\n)        sc\.addView\(ll\);/$1        ll.addView(head, 0);\n        sc.addView(ll);/' || fails=$((fails+1))
mut "C11 the search shows with no apps to search"     P 's/\n                    searchRow\.setVisibility\(View\.GONE\);//' || fails=$((fails+1))
mut "C12 a row that does not match is removed"        P 's/row\.setVisibility\(hit \? View\.VISIBLE : View\.GONE\);/if (!hit) { list.removeView(row); i--; }/' || fails=$((fails+1))
mut "C13 a row has no key to match"                   P 's/\n        tag\.key = AppFilter\.key\(rowLabel, pkg\);[^\n]*//' || fails=$((fails+1))
mut "C14 the query is logged"                         P 's/(        head\.addView\(searchRow, srlp\);\n)/$1        android.util.Log.i("NowhereChooser", "your apps search " + search.getText());\n/' \
    "BACK  a log line in Your apps (the query is profile content)" || fails=$((fails+1))
mut "C15 the query is written to the files dir"       P 's/(                applyPendingRow\(ll, summary, pendingRowView, pendingShown, pendingAuto\.size\(\)\);\n)/$1                try (java.io.FileWriter w = new java.io.FileWriter(new java.io.File(getFilesDir(), "q"))) { w.write(search.getText().toString()); } catch (Throwable ignore) {}\n/' \
    "BACK  a file write in Your apps (the files dir roams)" || fails=$((fails+1))
mut "C16 the search key leaves the keyboard up"       P 's/            hideKeyboard\(true\);\n            return true;/            return true;/' || fails=$((fails+1))
mut "C17 the keyboard stays up after you leave"       P 's/\{ hideKeyboard\(false\); \}/{}/' || fails=$((fails+1))
mut "C18 the keyboard may learn the query"            P 's/\n                \| android\.view\.inputmethod\.EditorInfo\.IME_FLAG_NO_PERSONALIZED_LEARNING\);/);/' || fails=$((fails+1))
mut "C19 Clear does nothing"                          P 's/clear\.setOnClickListener\(v -> search\.setText\(""\)\);/clear.setOnClickListener(v -> {});/' || fails=$((fails+1))
mut "C20 the matches are left below the fold"         P 's/\n                    sv\.post\(\(\) -> sv\.scrollTo\(0, list\.getTop\(\)\)\);//' || fails=$((fails+1))
mut "C21 the label cache read without the lock"       P 's/private synchronized java\.util\.HashMap<String,String> labelCache\(\) \{/private java.util.HashMap<String,String> labelCache() {/' || fails=$((fails+1))
mut "C22 a label looked up without the lock"          P 's/synchronized \(this\) \{ cached = labelCache\(\)\.get\(pkg\); \}/{ cached = labelCache().get(pkg); }/' || fails=$((fails+1))
mut "C23 the count line is not announced"             P 's/\n        count\.setAccessibilityLiveRegion\(View\.ACCESSIBILITY_LIVE_REGION_POLITE\);//' || fails=$((fails+1))
mut "C24 hidden rows are counted as matches"          P 's/if \(hit\) \{ shown\+\+; if \(t\.kept\) keptShown = true; \}/shown++; if (hit \&\& t.kept) keptShown = true;/' || fails=$((fails+1))
mut "C25 the search filters the whole screen"         P 's/if \(!applyYourAppsFilter\(list, s, count\)\) return;/if (!applyYourAppsFilter(ll, s, count)) return;/' || fails=$((fails+1))
mut "C26 the search scrolls away with the list"       P 's/        head\.addView\(searchRow, srlp\);/        ll.addView(searchRow, srlp);/' || fails=$((fails+1))
mut "C27 hideKeyboard never drops the field's focus" P 's/            if \(clear && f != null\) f\.clearFocus\(\);\n//' || fails=$((fails+1))
mut "C28 the labels sorted by package, not as shown"  P 's/otherLabels\.put\(p, String\.valueOf\(keptLabel\(p\)\)\);/otherLabels.put(p, p);/' || fails=$((fails+1))
# the absence checks, each proven alone: C14 and C15 above, these three and C40 below sit on showYourApps lines no pin
# covers (C14, C29, C30 and C40 in the seam between the head row's block and the count's)
mut "C29 a bare EditText joins the head"              P 's/(        head\.addView\(searchRow, srlp\);\n)/$1        head.addView(new EditText(this));\n/' \
    "BACK  a bare EditText in Your apps" || fails=$((fails+1))
mut "C30 a bare qualified EditText joins the head"    P 's/(        head\.addView\(searchRow, srlp\);\n)/$1        head.addView(new android.widget.EditText(this));\n/' \
    "BACK  a bare qualified EditText in Your apps" || fails=$((fails+1))
mut "C31 the list thread logs the rows"               P 's/(                final java\.util\.LinkedHashSet<String> keptNow;\n)/                android.util.Log.i("NowhereChooser", "your apps " + pkgs);\n$1/' \
    "BACK  a log line in Your apps (the query is profile content)" || fails=$((fails+1))
# the row drag released on the field: the refusal removed, or falling through
mut "C32 the field takes the row drag"                P 's/\n        search\.setOnDragListener\(\(v, e\) -> true\);//' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C33 the field's drag listener falls through"     P 's/search\.setOnDragListener\(\(v, e\) -> true\);/search.setOnDragListener((v, e) -> false);/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
# hideKeyboard, whole
mut "C34 hideKeyboard has no window to hide from"     P 's/android\.os\.IBinder tok = \(f != null\) \? f\.getWindowToken\(\)\n\s+: getWindow\(\)\.getDecorView\(\)\.getWindowToken\(\);/android.os.IBinder tok = null;/' \
    "PIN   hideKeyboard finds the field, hides, and drops focus only when asked" || fails=$((fails+1))
mut "C35 hideKeyboard never finds the field"          P 's/View f = getCurrentFocus\(\);/View f = null;/' \
    "PIN   hideKeyboard finds the field, hides, and drops focus only when asked" || fails=$((fails+1))
# the row drag again: guarded, commented out, moved, or undone by a second listener after the field's block
mut "C36 the drag listener is behind an if (false)"   P 's/\n(        search\.setOnDragListener\(\(v, e\) -> true\);\n)/\n        if (false)\n$1/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C37 the drag listener is commented out"          P 's/\n(        search\.setOnDragListener\(\(v, e\) -> true\);\n)/\n\/\/$1/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C38 the drag listener moved where it rarely runs" P 's/\n        search\.setOnDragListener\(\(v, e\) -> true\);\n/\n/; s/(\n                        summary\.setText\("Updating ")/\n                        search.setOnDragListener((v, e) -> true);$1/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C39 the drag listener is in a block comment"     P 's/\n(        search\.setOnDragListener\(\(v, e\) -> true\);\n)/\n        \/*\n$1        *\/\n/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C40 a second drag listener undoes the refusal"   P 's/(        head\.addView\(searchRow, srlp\);\n)/$1        search.setOnDragListener(null);\n/' \
    "BACK  a second drag listener on the field (it would undo the refusal)" || fails=$((fails+1))
# the other blocks: an `if (false)` or a comment put just above the first statement each block exists for. Every block
# starts at a declaration, a signature or the brace that ends the statement before, so that line lands inside it
mut "C41 leaving no longer hides the keyboard"        P 's/\n(        search\.addOnAttachStateChangeListener\(new View\.OnAttachStateChangeListener\(\) \{\n)/\n        if (false)\n$1/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C42 the search key no longer hides the keyboard" P 's/\n(        search\.setOnEditorActionListener\(\(v, action, ev\) -> \{\n)/\n        if (false)\n$1/' \
    "PIN   the field is a SafeEdit filter that learns nothing, takes no drag, and puts the keyboard away on search and on leaving" || fails=$((fails+1))
mut "C43 Clear is never wired"                        P 's/(        clear\.setPadding\(dp\(14\), dp\(12\), dp\(4\), dp\(12\)\);\n)(        clear\.setContentDescription\("Clear search"\);\n        clear\.setVisibility\(View\.GONE\);\n        clear\.setOnClickListener\(v -> search\.setText\(""\)\);\n)/$1        \/*\n$2        *\/\n/' \
    "PIN   Clear empties the field, and shows only with text" || fails=$((fails+1))
mut "C44 the field is never put in the head"          P 's/(        searchRow\.setGravity\(Gravity\.CENTER_VERTICAL\);\n)(        searchRow\.addView\(search, )/$1        if (false)\n$2/' \
    "PIN   the field and Clear sit in the head" || fails=$((fails+1))
mut "C45 the search never filters"                    P 's/(        head\.addView\(count, cnlp\);\n)(        search\.addTextChangedListener\()/$1        if (false)\n$2/' \
    "PIN   the count line sits in the head, hidden and announced, and every keystroke re-applies the search and brings the matches up" || fails=$((fails+1))
mut "C46 Your apps is never presented"                P 's/\n(        finishMenuScreen\(ll, this::showPreferences, head\);)/\n        if (false)\n$1/' \
    "PIN   Your apps is presented with its head pinned" || fails=$((fails+1))
mut "C47 Back does nothing"                           P 's/\n(        back\.setOnClickListener\(v -> onBack\.run\(\)\);\n        if \(head == null\))/\n        if (false)\n$1/' \
    "PIN   finishMenuScreen adds Back and presents a head outside the scroll" || fails=$((fails+1))
mut "C48 the order block is commented out"            P 's/\n(                java\.util\.List<String> sorted = KeepOrder\.keptFirst\(pkgs, keptNow\);\n(?:.*\n){10}                \/\/ NWP-20261012-06: each kept row\x27s "Wake for notifications"[^\n]*\n)/\n                \/*\n$1                *\/\n/' \
    "PIN   the other rows go A to Z after keptFirst, on the list thread" || fails=$((fails+1))
mut "C49 with no apps the branch falls through"       P 's/\n(                    list\.addView\(empty\);\n(?:.*\n){3}                    return;\n)/\n                    if (false) {\n$1                    }\n/' \
    "PIN   with no apps the search is hidden" || fails=$((fails+1))
mut "C50 no row is ever listed"                       P 's/\n(                for \(String p : pkgs\)\n                    list\.addView\(appKeepRow\()/\n                if (false)\n$1/' \
    "PIN   a mode change re-applies the search, the rows take it, and a query typed while loading applies" || fails=$((fails+1))
mut "C51 a row neither shows nor hands over its handle" P 's/\n(        row\.addView\(handle, new LinearLayout\.LayoutParams\(WRAP, WRAP\)\);\n        tag\.handle = handle;[^\n]*\n)/\n        \/*\n$1        *\/\n/' \
    "PIN   each row hands its handle to the filter" || fails=$((fails+1))
mut "C52 a repaint never updates the kept flag"       P 's/(        final ModePreview orderWake = m -> \{\n)(            tag\.kept = m != null;\n)/$1            if (false)\n$2/' \
    "PIN   a repaint keeps the handle hidden under a search" || fails=$((fails+1))
# NWP-20261111-13: the rows with no launcher icon and their picker (Q140).
mut "N1 launcherless keeps gms"                       O 's/if \(p\.equals\(gms\) \|\| p\.equals\(gsf\)\) continue;/if (p.equals(gsf)) continue;/' || fails=$((fails+1))
mut "N2 launcherless keeps a system app"              O 's/\n            if \("1"\.equals\(r\[1\]\)\) continue;//' || fails=$((fails+1))
mut "N3 keepModes(false) offers On-demand"            O 's/(        if \(hasIcon\) \{\n)(            out\.add\(new String\[\] \{ "On-demand[^\n]*\n)/$2$1/' || fails=$((fails+1))
mut "N4 the list thread skips the launcher-less pass" P 's/\n(                for \(String p : AppFilter\.launcherless\()/\n                if (false)\n$1/' \
    "PIN   the launcher-less pass lists this user's icon-less apps through the shared seen, before the lock" || fails=$((fails+1))
mut "N5 the picker offers every mode to an icon-less app" P 's/AppFilter\.keepModes\(hasIcon\)/AppFilter.keepModes(true)/' \
    "PIN   the picker builds its items and the checked row from keepModes" || fails=$((fails+1))
mut "N6 the picker never learns which rows have no icon" P 's/\n                yourAppsNoIcon = noIcon;[^\n]*//' \
    "PIN   the icon-less rows reach the picker before any row is painted" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
