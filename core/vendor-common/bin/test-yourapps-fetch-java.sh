#!/usr/bin/env bash
# test-yourapps-fetch-java.sh [--mutate] -- a tap on a Your apps icon with no code asks with the size, then fetches,
# run under javac (NWP-20261205-12).
#
# WHY THIS IS COMMITTED. The backlog row "Tapping an app that is not on the phone in Your apps does not fetch it"
# (DECIDED UNBUILT 2026-11-06; the row is the record): Chester, '"Your Apps", can we make tapping on an icon of an app
# will materialize it if not already installed?', and "lets follow the same style as play setup". So the tap sizes the
# app (APP-FETCH-SIZE), asks in dn-1023 #5's question (PlayFetchAskActivity), and on Download starts UnarchiveService
# as StoreService.materializeOwn does. Which rows ask is nApps' Download rule, StoreService.mayMaterializeOwn.
# YourAppsFetch (sizeSet, message) and PlayFetchAsk.CONFIRMED (the one-shot mark that keeps materializeLocked from
# asking twice) are pure and compiled here with their cases. Source checks pin the wiring the cases cannot see:
#   S1 the icon listener only behind keepRowFetch, filled through mayMaterializeOwn on the list thread;
#   S2 yourAppsTap's order: the rule, the size, the ask, and only after YES the rule again, the mark, the start;
#   S3 materializeLocked takes the mark only for a tap (`!quiet`) and skips the ask on it;
#   S4 the activity's body reads EXTRA_PLAY, default true (the Play setup's words);
#   S5 one asker never ends another's question (dismiss(t) by token, the LIVE token).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-yourapps-fetch-java.sh            # the cases + the source check
#   bash test-yourapps-fetch-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
YAF="$SRC/YourAppsFetch.java"
PFA="$SRC/PlayFetchAsk.java"
PA="$SRC/ProfileActivity.java"
UNA="$SRC/UnarchiveService.java"
ACT="$SRC/PlayFetchAskActivity.java"
CASES="$root/core/chooser/tests/yourapps-fetch/YourAppsFetchCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
[ -f "$PFA" ] && [ -f "$PA" ] && [ -f "$UNA" ] && [ -f "$ACT" ] || {
  echo "FAIL: missing PlayFetchAsk.java, ProfileActivity.java, UnarchiveService.java or PlayFetchAskActivity.java" >&2; exit 2; }

# suite <YourAppsFetch.java> <PlayFetchAsk.java> -> 0 pass, 1 a case failed or YourAppsFetch is missing (the only
# codes that convict a mutant), 3 the classes or the cases did not compile.
suite() {
  local yaf="$1" pfa="$2" d out rc
  [ -f "$yaf" ] || { echo "  FAIL  YourAppsFetch.java does not exist (the tap is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$yaf" "$d/src/com/nowhere/chooser/YourAppsFetch.java"
  cp "$pfa" "$d/src/com/nowhere/chooser/PlayFetchAsk.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/YourAppsFetchCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.YourAppsFetchCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# meth <file> <declaration text> -> the method's code lines, from the 4-space line holding the declaration text to
# its 4-space closing brace. Comment lines (//, *, /*) are dropped and a trailing ` // ...` is cut, so a comment
# never counts as code.
meth() {
  awk -v n="$2" 'index($0, n) && /^    [@a-zA-Z]/ && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1" |
    awk '/^ *(\/\/|\*|\/\*)/ { next } { sub(/[ \t]+\/\/.*$/, ""); print }'
}

# listthread <ProfileActivity.java> -> showYourApps' list thread: from its `new Thread(` to `ll.removeView(spin);`.
listthread() {
  meth "$1" " showYourApps(" | awk 'index($0, "new Thread(") && !f { f = 1 } f { print } f && index($0, "ll.removeView(spin);") { exit }'
}

# sources <ProfileActivity.java> <UnarchiveService.java> <PlayFetchAskActivity.java> -> 0 when every wiring rule
# holds, 1 (with the reason) when not.
sources() {
  local pa="$1" una="$2" act="$3" kr tap lt ml oc a5 a4 dm sh r
  kr=$(meth "$pa" " appKeepRow(")
  tap=$(meth "$pa" " yourAppsTap(")
  lt=$(listthread "$pa")
  ml=$(meth "$una" " materializeLocked(")
  oc=$(meth "$act" " onCreate(")
  a5=$(meth "$act" "static PlayFetchAsk.Reply ask(Context ctx, String pkg, long bytes, boolean play, long waitMs)")
  a4=$(meth "$act" "static PlayFetchAsk.Reply ask(Context ctx, String pkg, long bytes, long waitMs)")
  dm=$(meth "$act" "static void dismiss(long t)")
  sh=$(meth "$act" "static boolean showing()")
  [ -n "$kr" ] || { echo "  FAIL  S1 ProfileActivity: appKeepRow not found" >&2; return 1; }
  [ -n "$tap" ] || { echo "  FAIL  S2 ProfileActivity: yourAppsTap not found" >&2; return 1; }
  [ -n "$lt" ] || { echo "  FAIL  S1 ProfileActivity: showYourApps' list thread not found" >&2; return 1; }
  [ -n "$ml" ] || { echo "  FAIL  S3 UnarchiveService: materializeLocked not found" >&2; return 1; }
  [ -n "$oc" ] && [ -n "$a5" ] && [ -n "$a4" ] || { echo "  FAIL  S4 PlayFetchAskActivity: onCreate or an ask overload not found" >&2; return 1; }
  # S1a: one icon listener in appKeepRow, calling yourAppsTap(pkg), inside the keepRowFetch.contains(pkg) block.
  r=$(printf '%s\n' "$kr" | awk '
    index($0, "if (keepRowFetch.contains(pkg)) {") && !g { g = NR }
    g && !c && NR > g && /^        }$/ { c = NR }
    index($0, "icon.setOnClickListener(") { n++; l = NR; if (index($0, "yourAppsTap(pkg)")) y = 1 }
    END { if (n == 1 && y && g && c && g < l && l < c) print "ok"
          else print "bad: listeners=" n+0 " calls-yourAppsTap=" y+0 " guard=" g+0 " listener=" l+0 " close=" c+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S1a appKeepRow: $r (want one icon.setOnClickListener(... yourAppsTap(pkg) ...) inside \`if (keepRowFetch.contains(pkg)) {\`)" >&2; return 1; }
  # S1b: no PM or keep-set read for it on the UI thread.
  r=$(printf '%s\n' "$kr" | awk 'index($0, "mayMaterializeOwn(") || index($0, "deferredKeepSet(") { c++ } END { print c+0 }')
  [ "$r" = 0 ] || { echo "  FAIL  S1b appKeepRow reads mayMaterializeOwn( or deferredKeepSet( on the UI thread ($r line(s))" >&2; return 1; }
  # S1c: the list thread clears keepRowFetch, reads the keep-set once before the loop, and adds only under the rule.
  r=$(printf '%s\n' "$lt" | awk '
    index($0, "keepRowFetch.clear();") && !cl { cl = NR }
    index($0, "deferredKeepSet(this)") { k++; kl = NR }
    index($0, "keepRowFetch.add(") { a++; al = NR; if (index($0, "StoreService.mayMaterializeOwn(")) g = 1
          else if (index(prev, "StoreService.mayMaterializeOwn(") && prev ~ /^ *if \(/) g = 1 }
    { prev = $0 }
    END { if (cl && k == 1 && a == 1 && g && cl < kl && kl < al) print "ok"
          else print "bad: clear=" cl+0 " keep-set-reads=" k+0 " adds=" a+0 " guarded=" g+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S1c showYourApps list thread: $r (want keepRowFetch.clear(); one deferredKeepSet(this); one keepRowFetch.add( under \`if (StoreService.mayMaterializeOwn(\`)" >&2; return 1; }
  # S2: yourAppsTap's order, and the start only after YES.
  r=$(printf '%s\n' "$tap" | awk '
    index($0, "mayMaterializeOwn(") { m++; if (m == 1) m1 = NR; if (m == 2) m2 = NR }
    index($0, "\"APP-FETCH-SIZE\\n\"") && !s { s = NR }
    index($0, "PlayFetchAskActivity.ask(") { k++; kl = NR; if (index($0, ", play, ")) kp = 1 }
    index($0, "== PlayFetchAsk.Reply.YES") && !y { y = NR }
    index($0, "CONFIRMED.mark(") { mk++; mkl = NR }
    index($0, "startForegroundService(") { f++; fl = NR }
    fl && !fe { st = st $0; if (index($0, ";")) fe = NR }
    index($0, "KEEP_ROW_WRITES") { kw++ }
    END { ex = index(st, "UnarchiveService.EXTRA_PKG") && !index(st, "EXTRA_ID")
          if (m == 2 && k == 1 && kp && mk == 1 && f == 1 && ex && !kw && m1 < s && s < kl && kl < y && y < m2 && m2 < mkl && mkl < fl) print "ok"
          else print "bad: rule=" m+0 "@" m1+0 "," m2+0 " size=" s+0 " ask=" k+0 "@" kl+0 " play=" kp+0 " yes=" y+0 " mark=" mk+0 "@" mkl+0 " start=" f+0 "@" fl+0 " extra-pkg=" ex+0 " keep-row-writes=" kw+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S2 yourAppsTap: $r (want rule < APP-FETCH-SIZE < ask(..., play, ...) < == YES < rule < CONFIRMED.mark( < the one startForegroundService(... UnarchiveService.EXTRA_PKG ...))" >&2; return 1; }
  # S3: materializeLocked takes the mark once, only for a tap, before the ask; the ask's if begins `!asked &&`.
  r=$(printf '%s\n' "$ml" | awk '
    index($0, "PlayFetchAsk.CONFIRMED.take(") { t++; tl = NR; if (index($0, "!quiet && PlayFetchAsk.CONFIRMED.take(")) q = 1 }
    index($0, "PlayFetchAsk.needsAsk(") && !n { n = NR; l = $0; sub(/^ +/, "", l); if (index(l, "if (!asked && PlayFetchAsk.needsAsk(quiet, deps,") == 1) b = 1 }
    END { if (t == 1 && q && n && tl < n && b) print "ok"
          else print "bad: take=" t+0 "@" tl+0 " under-!quiet=" q+0 " needsAsk=" n+0 " if-!asked=" b+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S3 materializeLocked: $r (want \`!quiet && PlayFetchAsk.CONFIRMED.take(\` once, before \`if (!asked && PlayFetchAsk.needsAsk(quiet, deps,\`)" >&2; return 1; }
  # S4: the body reads EXTRA_PLAY with default true; the 5-argument ask puts it; the 4-argument one passes true.
  r=$(printf '%s\n' "$oc" | awk 'index($0, "body.setText(") && index($0, "getBooleanExtra(EXTRA_PLAY, true)") && index($0, "PlayFetchAsk.message(bytes)") && index($0, "YourAppsFetch.message(bytes, false)") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S4 onCreate: the body line does not read getBooleanExtra(EXTRA_PLAY, true) into PlayFetchAsk.message(bytes) / YourAppsFetch.message(bytes, false) ($r)" >&2; return 1; }
  r=$(printf '%s\n' "$a5" | awk 'index($0, ".putExtra(EXTRA_PLAY, play)") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S4 ask(..., play, waitMs) does not put EXTRA_PLAY ($r)" >&2; return 1; }
  r=$(printf '%s\n' "$a4" | awk 'index($0, "return ask(ctx, pkg, bytes, true, waitMs);") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S4 ask(ctx, pkg, bytes, waitMs) does not delegate with play = true ($r)" >&2; return 1; }
  # S5a: no no-argument dismiss; dismiss(long t) finishes only the question of its own token.
  r=$(awk '!/^ *(\/\/|\*|\/\*)/ && index($0, "static void dismiss()") { c++ } END { print c+0 }' "$act")
  [ "$r" = 0 ] || { echo "  FAIL  S5a PlayFetchAskActivity still has a no-argument dismiss()" >&2; return 1; }
  r=$(printf '%s\n' "$dm" | awk 'index($0, "finish") { f++; if (index($0, "a.token == t")) g++ } END { print f+0 " " g+0 }')
  [ "$r" = "1 1" ] || { echo "  FAIL  S5a dismiss(long t): a finish not under \`a.token == t\` (finish lines, guarded: $r)" >&2; return 1; }
  # S5b: the TIMEOUT dismisses this ask's question only.
  r=$(printf '%s\n' "$a5" | awk 'index($0, "if (r == PlayFetchAsk.Reply.TIMEOUT) dismiss(t);") { t++ } index($0, "dismiss()") { b++ } END { print t+0 " " b+0 }')
  [ "$r" = "1 0" ] || { echo "  FAIL  S5b ask: want \`if (r == PlayFetchAsk.Reply.TIMEOUT) dismiss(t);\` once and no dismiss() (got $r)" >&2; return 1; }
  # S5c: ASKER.open() and LIVE.set( under one lock; LIVE.compareAndSet(t, 0) in a finally.
  r=$(printf '%s\n' "$a5" | awk '
    index($0, "synchronized (PlayFetchAskActivity.class) {") && !s { s = NR }
    s && !c && NR > s && /^        }$/ { c = NR }
    index($0, "PlayFetchAsk.ASKER.open()") { o = NR }
    index($0, "LIVE.set(") { l = NR }
    index($0, "} finally {") { fi = NR }
    index($0, "LIVE.compareAndSet(t, 0)") { cs = NR }
    END { if (s && s < o && o < c && s < l && l < c && fi && fi < cs) print "ok"
          else print "bad: lock=" s+0 "-" c+0 " open=" o+0 " live-set=" l+0 " finally=" fi+0 " live-clear=" cs+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S5c ask: $r (want ASKER.open() and LIVE.set( in one synchronized block, LIVE.compareAndSet(t, 0) in a finally)" >&2; return 1; }
  # S5d: showing() also reads the live token.
  r=$(printf '%s\n' "$sh" | awk 'index($0, "return current != null || LIVE.get() != 0;") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S5d showing() does not return \`current != null || LIVE.get() != 0\` ($r)" >&2; return 1; }
  # S5e: a stale question never shows; an older one is finished only for another token.
  r=$(printf '%s\n' "$oc" | awk '
    index($0, "token = in != null") && !tk { tk = NR }
    index($0, "if (token != LIVE.get()) { finish(); return; }") && !st { st = NR }
    index($0, "setContentView(") && !sc { sc = NR }
    index($0, "prev.finish()") { p++; if (index($0, "prev.token != token")) pg++ }
    END { if (tk && tk < st && st < sc && p == 1 && pg == 1) print "ok"
          else print "bad: token=" tk+0 " stale-check=" st+0 " setContentView=" sc+0 " prev.finish=" p+0 " guarded=" pg+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S5e onCreate: $r (want the token read < \`if (token != LIVE.get()) { finish(); return; }\` < setContentView, and prev.finish() only under prev.token != token)" >&2; return 1; }
  return 0
}

echo "== $YAF"
ok=yes
suite "$YAF" "$PFA" || ok=no
sources "$PA" "$UNA" "$ACT" || ok=no
[ "$ok" = yes ] || { echo "FAILED"; exit 1; }
echo "ok: cases + source check"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <file: yaf|pfa|pa|una|act> <perl-expr>
  local d c rc orig out why
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    yaf) orig="$YAF" ;; pfa) orig="$PFA" ;; pa) orig="$PA" ;; una) orig="$UNA" ;; *) orig="$ACT" ;;
  esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    yaf) out=$(suite "$c" "$PFA" 2>&1); rc=$? ;;
    pfa) out=$(suite "$YAF" "$c" 2>&1); rc=$? ;;
    pa) out=$(sources "$c" "$UNA" "$ACT" 2>&1); rc=$? ;;
    una) out=$(sources "$PA" "$c" "$ACT" 2>&1); rc=$? ;;
    *) out=$(sources "$PA" "$UNA" "$c" 2>&1); rc=$? ;;
  esac
  rm -rf "$d"
  why=$(printf '%s\n' "$out" | awk '/FAIL/ { sub(/^ +/, ""); print; exit }')
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1 -- $why"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "X1 keepRowFetch filled without the mayMaterializeOwn test" pa  's/\n *if \(StoreService\.mayMaterializeOwn\(UnarchiveService\.hasInstalledCode\(this, p\)[^\n]*//' || fails=$((fails+1))
mut "X2 sizeSet keeps a dep with code"                  yaf 's/d != null && !hasCode\.test\(d\)/d != null/' || fails=$((fails+1))
mut "X3 message(-1, false) returns PlayFetchAsk.UNKNOWN" yaf 's/return playStack \? PlayFetchAsk\.UNKNOWN : UNKNOWN_APP;/return PlayFetchAsk.UNKNOWN;/' || fails=$((fails+1))
mut "X4 take does not remove the mark"                  pfa 's/Long t = marks\.remove\(pkg\);/Long t = marks.get(pkg);/' || fails=$((fails+1))
mut "X5 take ignores CONFIRM_MS"                        pfa 's/ && now - t <= CONFIRM_MS;/;/' || fails=$((fails+1))
mut "X6 materializeLocked takes CONFIRMED for quiet too" una 's/boolean asked = !quiet && /boolean asked = /' || fails=$((fails+1))
mut "X7 !asked dropped from the ask's if"               una 's/if \(!asked && PlayFetchAsk\.needsAsk\(/if (PlayFetchAsk.needsAsk(/' || fails=$((fails+1))
mut "X8 yourAppsTap marks before the ask's reply"       pa  's/(\n *PlayFetchAsk\.Reply reply = PlayFetchAskActivity\.ask\([^\n]*)(.*?)(\n *PlayFetchAsk\.CONFIRMED\.mark\([^\n]*)/$3$1$2/s' || fails=$((fails+1))
mut "X9 the EXTRA_PLAY default flipped to false"        act 's/getBooleanExtra\(EXTRA_PLAY, true\)/getBooleanExtra(EXTRA_PLAY, false)/' || fails=$((fails+1))
mut "X10 the icon listener outside the keepRowFetch guard" pa 's/(\n *if \(keepRowFetch\.contains\(pkg\)\) \{)(.*?)(\n *icon\.setOnClickListener\(v -> yourAppsTap\(pkg\)\);)/$3$1$2/s' || fails=$((fails+1))
mut "X11 dismiss(t) finishes without the token test"    act 's/if \(a != null && a\.token == t\)/if (a != null)/' || fails=$((fails+1))
mut "X12 showing() ignores the live token"              act 's/return current != null \|\| LIVE\.get\(\) != 0;/return current != null;/' || fails=$((fails+1))
mut "X13 onCreate shows a stale question"               act 's/\n *if \(token != LIVE\.get\(\)\) \{ finish\(\); return; \}//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
