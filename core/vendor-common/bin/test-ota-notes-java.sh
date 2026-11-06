#!/usr/bin/env bash
# test-ota-notes-java.sh [--mutate] -- the gate's "what's in it" and "what's new" dialogs, run under javac
# (NWP-20261012-03).
#
# WHY THIS IS COMMITTED. Both lines of the Software update screen used to open one dialog, titled "What's new", that
# held the offered versions AND the installed one's notes. Which notes each line shows, the title it carries, and the
# copy around the published points live in core/chooser/src/com/nowhere/chooser/OtaNotes.java. Nothing else executes
# them off a device. core/chooser/tests/ota-notes/run.sh compiles that file as it stands, with OtaNotesCases.
#
# THE CALL SITES ARE PINNED, AS BLOCKS. A correct helper called with the wrong mode is the original bug again, and the
# cases never see the call. The pins hold each wiring block byte for byte, and the call-site mutations at the end must
# each be convicted by one. NWP-20261124-14: Profile's Update card is pinned the same way -- it asks OTA-NOTES off
# the UI thread, renders through OtaNotes.cardNotes, still has its one button, and shows only when an update is.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it. The version
# is printed first so the log proves which compiler ran.
#
#   bash test-ota-notes-java.sh            # the cases + the pins
#   bash test-ota-notes-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/OtaNotes.java"
CHO="$DIR/ChooserActivity.java"
PRO="$DIR/ProfileActivity.java"
RUN="$root/core/chooser/tests/ota-notes/run.sh"
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
# One temp root, removed on exit; run.sh's own temp dir and every mutant land inside it.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$CHO" "$PRO" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# ---- the pinned blocks (quoted heredocs: every backslash below is literal source text) ----
IFS= read -r -d '' P_INIT <<'EOF'
                swCurrent.setText(withLink("Current version:  " + curF + "  ·  ", "what's in it"));
                swCurrent.setOnClickListener(v -> showOtaNotes(OtaNotes.Mode.IN_IT));
EOF
IFS= read -r -d '' P_NEW <<'EOF'
                msg.setText(android.text.TextUtils.concat(withLink("Update available" + verParen + "  ·  ", "what's new"), detail));
                msg.setOnClickListener(v -> showOtaNotes(OtaNotes.Mode.NEW));
EOF
IFS= read -r -d '' P_DIALOG <<'EOF'
    private void showOtaNotes(final OtaNotes.Mode mode) {
        new Thread(() -> {
            final OtaNotes.View view = OtaNotes.render(DaemonSocket.roundTripLines("OTA-NOTES\n", 5000), mode);
            runOnUiThread(() -> {
                try {
                    new android.app.AlertDialog.Builder(this).setTitle(view.title).setMessage(view.body)
                            .setPositiveButton("OK", null).show();
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "OTA notes dialog", t); }
            });
        }, "nowhere-ota-notes").start();
    }
EOF

IFS= read -r -d '' P_CARD_ASK <<'EOF'
        new Thread(() -> {
            final String body = OtaNotes.cardNotes(DaemonSocket.roundTripLines("OTA-NOTES\n", 5000));
            if (body == null) return;
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed() || !card.isAttachedToWindow()) return; // a redraw replaced this card
                notes.setText(body);
                notesHdr.setVisibility(android.view.View.VISIBLE);
                notes.setVisibility(android.view.View.VISIBLE);
            });
        }, "nowhere-update-card-notes").start();
EOF
IFS= read -r -d '' P_CARD_BUTTON <<'EOF'
        card.addView(accentButton("Sign out & install", () -> confirmSignOutAndInstall(local)), btnLp(dp(12)));
    }
EOF
IFS= read -r -d '' P_CARD_WHEN <<'EOF'
        if (us.avail) addUpdateCard(ll, us, local);
EOF

# pinned <file> <label> <block>: the block must appear verbatim in the file.
pinned() {
  local body; body=$(cat "$1")
  [[ "$body" == *"$3"* ]] && return 0
  echo "  PIN   $2 -- the block is gone or changed in $(basename "$1")" >&2
  return 1
}

# suite <OtaNotes> <ChooserActivity> <ProfileActivity> -> 0 pass; 1 a case or a pin failed (a pin is how a call-site
# mutant is convicted); 3 the class or the cases did not compile.
suite() {
  local o="$1" c="$2" p="$3" bad=0 n m
  pinned "$c" "the version line opens \"what's in it\""             "$P_INIT"   || bad=1
  pinned "$c" "the update line opens \"what's new\""                "$P_NEW"    || bad=1
  pinned "$c" "the dialog shows the mode's title and body"         "$P_DIALOG" || bad=1
  n=$(grep -o 'showOtaNotes(' "$c" | wc -l | tr -d ' ')
  [ "$n" = 3 ] || { echo "  PIN   showOtaNotes( appears $n times, want 3 (the method + its two lines)" >&2; bad=1; }
  # Profile's Update card (NWP-20261124-14)
  pinned "$p" "the card asks OTA-NOTES off the UI thread, through cardNotes" "$P_CARD_ASK"    || bad=1
  pinned "$p" "the card ends with its one button"                           "$P_CARD_BUTTON" || bad=1
  pinned "$p" "the card shows only when an update is available"             "$P_CARD_WHEN"   || bad=1
  m=$(mktemp -p "$W") || return 2
  awk '/^    private void addUpdateCard\(/{on=1} on{print} on && /^    }$/{exit}' "$p" > "$m"
  n=$(grep -o 'Button(' "$m" | wc -l | tr -d ' ')
  [ "$n" = 1 ] || { echo "  PIN   addUpdateCard has $n buttons, want 1 (Sign out & install)" >&2; bad=1; }
  n=$(grep -o '"OTA-NOTES' "$m" | wc -l | tr -d ' ')
  [ "$n" = 1 ] || { echo "  PIN   addUpdateCard asks \"OTA-NOTES\" $n times, want 1 (one request, in the thread)" >&2; bad=1; }
  rm -f "$m"
  n=$(grep -o 'addUpdateCard(' "$p" | wc -l | tr -d ' ')
  [ "$n" = 2 ] || { echo "  PIN   addUpdateCard( appears $n times, want 2 (the method + its one call)" >&2; bad=1; }
  [ "$bad" = 0 ] || return 1
  bash "$RUN" "$o"
}

echo "== $SRC (+ pins in $(basename "$CHO") and $(basename "$PRO"))"
suite "$SRC" "$CHO" "$PRO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not compile proves nothing)"
# mut <label> <which: O|C|P> <perl-expr>
mut() {
  local d rc o="$SRC" c="$CHO" p="$PRO" t
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in O) t="$SRC" ;; C) t="$CHO" ;; P) t="$PRO" ;; esac
  local m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in O) o="$m" ;; C) c="$m" ;; P) p="$m" ;; esac
  suite "$o" "$c" "$p" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "N1 the two modes swapped"                       O 's/if \(mode == Mode\.IN_IT\) \{/if (mode == Mode.NEW) {/' || fails=$((fails+1))
mut "N2 one step titled plain What.s new"            O 's/new View\("What\x27s new in " \+ top\.version, /new View("What\x27s new", /' || fails=$((fails+1))
mut "N3 one block + MORE taken as one step"          O 's/if \(r\.offered\.size\(\) == 1 && !r\.more\) \{/if (r.offered.size() == 1) {/' || fails=$((fails+1))
mut "N4 the MORE line dropped"                       O 's/if \(r\.more\) b\.append/if (false) b.append/' || fails=$((fails+1))
mut "N5 no OFFERED falls back to the running notes"  O 's/return new View\("What\x27s new", r\.more \? NOT_AVAILABLE : NOT_READY\);/return new View("What\x27s new", bullets(r.running.points));/' || fails=$((fails+1))
mut "N6 offered notes land in the running version"   O 's/cur = new Version\(l\.substring\(8\)\.trim\(\)\); r\.offered\.add\(cur\);/r.offered.add(new Version(l.substring(8).trim()));/' || fails=$((fails+1))
mut "N7 sections oldest first"                       O 's/r\.offered\.add\(cur\);/r.offered.add(0, cur);/' || fails=$((fails+1))
mut "N8 Update: names the running version"           O 's/\.append\(" · Update: "\)\.append\(top\.version\)/.append(" · Update: ").append(running)/' || fails=$((fails+1))
mut "N9 several steps titled What.s new"             O 's/new View\("Changes since your version", /new View("What\x27s new", /' || fails=$((fails+1))
mut "N10 a cut-short reply rendered as new"          O 's/        if \(!r\.ended\) return new View\("What\x27s new", NOT_LOADED\);\n//' || fails=$((fails+1))
mut "N11 a cut-short reply rendered as in it"        O 's/            if \(!r\.ended\) return new View\(title, NOT_LOADED\);\n//' || fails=$((fails+1))
mut "N12 several steps repeat the running notes"     O 's/\.append\(" · Update: "\)\.append\(top\.version\);/.append(" · Update: ").append(top.version).append("\x5cn").append(bullets(r.running.points));/' || fails=$((fails+1))
mut "N13 lines after END are read"                   O 's/\{ r\.ended = true; break; \}/r.ended = true;/' || fails=$((fails+1))
mut "N14 in it titled What.s new"                    O 's/: "What\x27s in " \+ running;/: "What\x27s new";/' || fails=$((fails+1))
mut "N15 the old MORE wording"                       O 's/"…and earlier changes not listed\."/"…and earlier changes."/' || fails=$((fails+1))
mut "N16 in it with no notes says nothing"           O 's/r\.running\.points\.isEmpty\(\) \? NO_NOTES : /r.running.points.isEmpty() ? "" : /' || fails=$((fails+1))
mut "N17 the not-ready copy makes a claim"           O 's/aren\x27t ready yet\. Try again in a moment\./aren\x27t ready yet. Your data stays private./' || fails=$((fails+1))
mut "N18 a stray NOTE joins the running version"     O 's/if \(cur != null\) cur\.points\.add/if (cur != null || (cur = r.running) != null) cur.points.add/' || fails=$((fails+1))
mut "N19 not available and not ready swapped"       O 's/r\.more \? NOT_AVAILABLE : NOT_READY/r.more ? NOT_READY : NOT_AVAILABLE/' || fails=$((fails+1))
mut "N20 not available back to were published"      O 's/"No notes are available for this update yet\."/"No notes were published for this update."/' || fails=$((fails+1))
# call sites -- each must be convicted by a pin
mut "C1 the version line opens what's new"           C 's/swCurrent\.setOnClickListener\(v -> showOtaNotes\(OtaNotes\.Mode\.IN_IT\)\);/swCurrent.setOnClickListener(v -> showOtaNotes(OtaNotes.Mode.NEW));/' || fails=$((fails+1))
mut "C2 the update line opens what's in it"          C 's/msg\.setOnClickListener\(v -> showOtaNotes\(OtaNotes\.Mode\.NEW\)\);/msg.setOnClickListener(v -> showOtaNotes(OtaNotes.Mode.IN_IT));/' || fails=$((fails+1))
mut "C3 the dialog title is fixed"                   C 's/\.setTitle\(view\.title\)\.setMessage\(view\.body\)/.setTitle("What\x27s new").setMessage(view.body)/' || fails=$((fails+1))
mut "C4 the mode never reaches render"               C 's/roundTripLines\("OTA-NOTES\x5cn", 5000\), mode\);/roundTripLines("OTA-NOTES\x5cn", 5000), OtaNotes.Mode.NEW);/' || fails=$((fails+1))
mut "C5 a third line opens the notes"                C 's/(        TextView swHdr = new TextView\(this\);\n)/$1        swHdr.setOnClickListener(v -> showOtaNotes(OtaNotes.Mode.NEW));\n/' || fails=$((fails+1))
mut "C6 the notes read runs on the UI thread"       C 's/\}, "nowhere-ota-notes"\)\.start\(\);/}, "nowhere-ota-notes").run();/' || fails=$((fails+1))
mut "C7 the notes thread never starts"              C 's/\}, "nowhere-ota-notes"\)\.start\(\);/}, "nowhere-ota-notes");/' || fails=$((fails+1))
# Profile's Update card (NWP-20261124-14): K by the cases, P by a pin
mut "K1 the card renders what's in it"               O 's/return render\(lines, Mode\.NEW\)\.body;/return render(lines, Mode.IN_IT).body;/' || fails=$((fails+1))
mut "K2 an unended reply drawn as text"              O 's/        if \(!parse\(lines\)\.ended\) return null;\n//' || fails=$((fails+1))
mut "K3 the card shows the running notes"            O 's/return render\(lines, Mode\.NEW\)\.body;/return render(lines, Mode.NEW).body + "\x5cn" + bullets(parse(lines).running.points);/' || fails=$((fails+1))
mut "K4 the heading words changed"                   O 's/"What\x27s in this update"/"What\x27s new"/' || fails=$((fails+1))
mut "P1 the notes asked on the UI thread"            P 's/\}, "nowhere-update-card-notes"\)\.start\(\);/}, "nowhere-update-card-notes").run();/' || fails=$((fails+1))
mut "P2 a second button on the card"                 P 's/(        card\.addView\(accentButton\("Sign out & install", \(\) -> confirmSignOutAndInstall\(local\)\), btnLp\(dp\(12\)\)\);\n)/$1        card.addView(secondaryButton("Not now", () -> {}), btnLp(dp(10)));\n/' || fails=$((fails+1))
mut "P3 the notes thread never starts"               P 's/\}, "nowhere-update-card-notes"\)\.start\(\);/}, "nowhere-update-card-notes");/' || fails=$((fails+1))
mut "P4 the card bypasses cardNotes"                 P 's/OtaNotes\.cardNotes\(DaemonSocket\.roundTripLines\("OTA-NOTES\x5cn", 5000\)\)/OtaNotes.render(DaemonSocket.roundTripLines("OTA-NOTES\x5cn", 5000), OtaNotes.Mode.NEW).body/' || fails=$((fails+1))
mut "P5 a replaced card still written"               P 's/ \|\| !card\.isAttachedToWindow\(\)\)/)/' || fails=$((fails+1))
mut "P6 the card shows with no update"               P 's/if \(us\.avail\) addUpdateCard/if (true) addUpdateCard/' || fails=$((fails+1))
mut "P7 a second OTA-NOTES ask on the UI thread"     P 's/(        card\.addView\(notes, nlp\);\n)/$1        DaemonSocket.roundTripLines("OTA-NOTES\x5cn", 5000);\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
