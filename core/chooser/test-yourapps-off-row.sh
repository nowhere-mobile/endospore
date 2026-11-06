#!/usr/bin/env bash
# test-yourapps-off-row.sh [<ProfileActivity.java>] [--mutate] -- NWP-20260926-01: an app switched Off in
# "Your apps" stays a row, and stays switchable, until logoff; switching it back On retires its Off record.
#
# WHY THIS IS COMMITTED. On lynx 2026092609 (2026-09-26) Chester switched two on-demand apps Off and could not
# switch them back: at his next visit both rows were gone. The screen builds its rows from two sources -- the
# launcher query, which needs an APK on disk, and the keep-set -- and Off removes the keep line, so an ARCHIVED
# placeholder was in neither. The picker promises "Off — removed at logoff", and until logoff an Off is only
# a choice (DECIDED 2026-09-26); the screen took the way back away. The fix is three edits in separate
# methods, each of which a later edit could undo on its own without any build or test noticing:
#   * showYourApps has a THIRD row source: the Off record (nowhere-appoff.list) plus Play Store by name,
#     resolved for THIS user only -- no MATCH_ANY_USER, so only an app this login provisioned becomes a row --
#     read together with the keep-set in ONE hold of APPKEEP_LOCK (two reads could straddle an edit and lose
#     the row), on the background thread, through the one shared `seen` set, each item in its own try, with
#     the same Play-provider, bundled and system skips as the other passes;
#   * a keep line that lands retires the Off record (StoreInstaller.clearTurnedOff), called by writeAppModes
#     for the adds that write kept and by keepAutoImpl after its write. clearTurnedOff holds APPKEEP_LOCK,
#     re-reads the keep-set from disk and retires only a package that is kept: an Off record never goes for an
#     app that is not kept, which is the NWP-20260825-22 leak shape;
#   * the Off branch keeps a Play client's "needs Play" fact in nowhere-playseen before setPlayDep erases it
#     from nowhere-playdeps, so an Off -> On of an archived client brings its Play stack back.
# And it pins, unchanged, what those edits rely on: the row paints a mode-less app "Off" with its picker live;
# the summary skips a mode-less row; the Off branch still records the Off; captureAppDrops never drops a kept
# app named by the Off record; AppInstallReceiver checks the Off record before its returning-app reset; roamd's
# code-side drop is still the Off record intersected with the drop list.
#
# All checks run on CODE ONLY -- comments dropped, string, char and text-block literals emptied -- and on
# methods extracted by brace matching, then with whitespace removed, so a reformat changes nothing and prose
# cannot satisfy a check. The two checks that need a literal (the file clearTurnedOff writes, and the chip's
# "Off" label) read the same method with its literals kept and its comments still dropped. Extracted text is
# written to files and grepped there: `printf | grep -q` under pipefail can fail on SIGPIPE, a false red.
#
#   bash test-yourapps-off-row.sh            # the invariants
#   bash test-yourapps-off-row.sh --mutate   # ... plus mutations that must each CONVICT the suite, and
#                                            #     correct-code probes that must NOT
#
# The SUT argument replaces ProfileActivity.java. OFFROW_ST, OFFROW_AIR and OFFROW_ROAMD replace
# StoreInstaller.java, AppInstallReceiver.java and nowhere_roamd.sh, so a mutation can target each of them.
# The chooser has no unit-test harness; these are source-level checks in the style of test-appmode-lock.sh.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
ST="${OFFROW_ST:-$HERE/src/com/nowhere/chooser/StoreInstaller.java}"
AIR="${OFFROW_AIR:-$HERE/src/com/nowhere/chooser/AppInstallReceiver.java}"
ROAMD="${OFFROW_ROAMD:-$HERE/../vendor-common/bin/nowhere_roamd.sh}"
for f in "$SUT" "$ST" "$AIR" "$ROAMD"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# codeonly: one pass over the file, printing each line reduced to CODE -- line and block comments dropped,
# string, char and text-block literals emptied (the same scanner as test-appmode-lock.sh). KEEPLIT=1 keeps the
# literals and still drops the comments. One output line per input line, so line numbers carry across.
codeonly(){ awk -v SQ="'" -v KL="${KEEPLIT:-0}" '
  BEGIN { inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) {
        if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3; if (KL) code=code "\"\"\"" } else { if (KL) code=code c; i++ }
        continue
      }
      if (two=="//") break
      if (two=="/*") { inblock=1; i+=2; continue }
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code (KL ? "\"\"\"" : "\"\""); continue }
      if (c=="\"" || c==SQ) {
        q=c; st=i; i++
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        i++; code=code (KL ? substr($0, st, i-st) : q q); continue
      }
      code=code c; i++
    }
    print code
  }'; }
# mrange <file> <signature-regex>: "first last" line of the method, matched by brace on code only. rc 3 when
# the signature is missing or its braces do not balance. Reads to EOF: an early exit would SIGPIPE codeonly.
mrange(){ codeonly < "$1" | RE="$2" awk '
  !on && $0 ~ ENVIRON["RE"] { on=1; s=NR }
  on && !done { n=length($0); for (i=1;i<=n && !done;i++) { c=substr($0,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) { done=1; e=NR } } } }
  END { if (!done) exit 3; print s, e }'; }
# grab <file> <signature-regex> <out>: the method, code only, flattened (all whitespace removed) into <out>;
# with KEEPLIT=1, its literals kept. rc 3 when it cannot be extracted.
grab(){
  local r s e
  r=$(mrange "$1" "$2") || return 3
  s=${r% *}; e=${r#* }
  codeonly < "$1" | sed -n "${s},${e}p" | tr -d ' \t\r\n' > "$3"
  [ -s "$3" ]
}
# pos <flatfile> <needle>: 1-based index of the FIRST occurrence, 0 when absent.
pos(){ local p; p=$(N="$2" awk '{ print index($0, ENVIRON["N"]) }' "$1"); echo "${p:-0}"; }
# count <flatfile> <needle>
count(){ local c; c=$(N="$2" awk '{ s=$0; k=0; L=length(ENVIRON["N"]); while ((i=index(s, ENVIRON["N"]))>0) { k++; s=substr(s, i+L) } print k }' "$1"); echo "${c:-0}"; }
has(){ grep -qF -- "$2" "$1"; }
# before <flatfile> <a> <b>: both present and the first a precedes the first b.
before(){ local a b; a=$(pos "$1" "$2"); b=$(pos "$1" "$3"); [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; }
# slice <flatfile> <from> <loop> <out>: from the first <from> to the brace that closes the first <loop> after it.
slice(){ FROM="$2" LOOP="$3" awk '{
    i=index($0, ENVIRON["FROM"]); if (!i) exit 3
    r=substr($0, i); j=index(r, ENVIRON["LOOP"]); if (!j) exit 3
    d=0; n=length(r); e=0
    for (k=j; k<=n; k++) { c=substr(r, k, 1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) { e=k; break } } }
    if (!e) exit 3
    print substr(r, 1, e)
  }' "$1" > "$4" && [ -s "$4" ]; }

PA='com/nowhere/chooser'
grab "$SUT" 'private void showYourApps\(\) \{' "$T/sya" &&
grab "$SUT" 'private java.util.Set<String> writeAppModes\(java.util.Map<String,String> modes, Boolean overPlanNow\) \{' "$T/wam" &&
grab "$SUT" 'private java.util.Set<String> setAppModeLocked\(String pkg, String mode, Boolean overPlanNow\) \{' "$T/sam" &&
grab "$SUT" 'private LinearLayout appKeepRow\(final String pkg, Long sizeBytes, final boolean sideloaded, final Runnable onChange\) \{' "$T/akr" &&
grab "$SUT" 'private void captureAppDrops\(\) \{' "$T/cad" &&
KEEPLIT=1 grab "$SUT" 'private void paintModeChip\(TextView chip, String mode\) \{' "$T/pmc" &&
grab "$ST" 'private static boolean keepAutoImpl\(Context ctx, String pkg, boolean overPlan, String mode\) \{' "$T/kai" &&
grab "$AIR" 'private static boolean decide\(Context ctx, String pkg, boolean replacing, String via\) \{' "$T/dec" &&
{ slice "$T/sya" 'finallongkeptFlags=' 'for(Stringp:keptNow){' "$T/keeploop" ||
  slice "$T/sya" 'finallongkeptFlags=' 'for(Stringp:readAppKeep()){' "$T/keeploop"; } &&   # (the code before the slice)
slice "$T/cad" 'for(Stringp:explicitOff){' 'for(Stringp:explicitOff){' "$T/cadoff" ||
  { echo "EXTRACTION FAILED -- a method anchor moved, or its braces do not balance ($PA)" >&2; exit 2; }
# The two methods this slice ADDED text to are optional here, so the suite runs on the code before the slice and
# reports the missing behaviour as a failure rather than refusing to run.
CTO=yes; grab "$ST" 'static void clearTurnedOff\(Context ctx, java.util.Collection<String> pkgs\) \{' "$T/cto" || CTO=no
[ "$CTO" = yes ] && { KEEPLIT=1 grab "$ST" 'static void clearTurnedOff\(Context ctx, java.util.Collection<String> pkgs\) \{' "$T/ctolit" || CTO=no; }
OFFLOOP=yes; slice "$T/sya" 'finallongoffFlags=' 'for(Stringp:offNow){' "$T/offloop" || OFFLOOP=no

echo "== \"Your apps\" lists an app switched Off this session (the bug) =="
if [ "$OFFLOOP" = no ]; then
  no "showYourApps has no Off-record row source (no offFlags / for (String p : offNow) pass) -- an archived app switched Off vanishes at the next visit"
else
  SNAP='synchronized(StoreInstaller.APPKEEP_LOCK){keptNow=readAppKeep();offNow=explicitlyTurnedOff();}'
  if before "$T/sya" 'newThread(()->{' "$SNAP" &&
     before "$T/sya" "$SNAP" 'for(Stringp:keptNow){' &&
     before "$T/sya" 'for(Stringp:keptNow){' 'for(Stringp:offNow){' &&
     before "$T/sya" 'for(Stringp:offNow){' 'runOnUiThread('; then
    ok "the Off pass runs on the list thread, after the keep-set pass and before the rows are built on the UI thread"
  else
    no "the Off pass is out of order: it must follow the keep-set pass on the background thread and precede runOnUiThread"
  fi
  if [ "$(count "$T/sya" "$SNAP")" = 1 ] && [ "$(count "$T/sya" 'readAppKeep()')" = 1 ] &&
     [ "$(count "$T/sya" 'explicitlyTurnedOff()')" = 1 ]; then
    ok "the keep-set and the Off record are read together, in ONE hold of APPKEEP_LOCK, and nowhere else in the list build"
  else
    no "the keep-set and the Off record are not read together under APPKEEP_LOCK -- an edit landing between two reads loses the row"
  fi
  miss=""
  for n in 'finallongoffFlags=android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES|android.content.pm.PackageManager.MATCH_UNINSTALLED_PACKAGES;offNow.add(VENDING_PKG);' \
           'for(Stringp:offNow){if(getPackageName().equals(p)||!seen.add(p))continue;if(GMS_PKG.equals(p)||GSF_PKG.equals(p))continue;if(isBundledSystem(pm,p))continue;try{' \
           'pm.getApplicationInfo(p,android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));' \
           'if((ai.flags&(android.content.pm.ApplicationInfo.FLAG_SYSTEM|android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP))!=0)continue;pkgs.add(p);'; do
    has "$T/offloop" "$n" || miss="$miss $n"
  done
  if [ -z "$miss" ]; then
    ok "the Off pass reads the Off record plus Play Store, shares seen, skips gms/gsf, bundled and system apps, and lists only what PM resolves"
  else
    no "the Off pass lost:$miss"
  fi
  # Each item in its OWN try, and the row added once, inside it, after the lookup: a try around the whole loop
  # lets one stale Off line (an app uninstalled after its Off throws, by design) end the pass for every row
  # after it, and a row added in the catch lists apps that are not on the phone.
  if before "$T/offloop" 'ApplicationInfoFlags.of(offFlags)' 'pkgs.add(p);' &&
     [ "$(count "$T/offloop" 'pkgs.add(p);')" = 1 ] &&
     T2='side.put(p,sl);}catch(Throwableignore){}}' awk '{ t = ENVIRON["T2"]; exit !(substr($0, length($0) - length(t) + 1) == t) }' "$T/offloop"; then
    ok "an Off row is added only after PM resolved it, once, and each item fails alone (an app uninstalled after its Off is not listed)"
  else
    no "the Off pass adds a row before, without, or outside a per-item resolve"
  fi
  if has "$T/keeploop" 'MATCH_ANY_USER'; then
    if has "$T/offloop" 'MATCH_ANY_USER'; then
      no "the Off pass resolves with MATCH_ANY_USER -- an Off from an earlier session, held by another user, becomes a row"
    else
      ok "the Off pass resolves for THIS user only (no MATCH_ANY_USER; control: the keep-set pass does use it, so the check can see it)"
    fi
  else
    no "control lost: the keep-set pass no longer names MATCH_ANY_USER, so the absence check above proves nothing"
  fi
fi
if [ "$(count "$T/sya" 'LinkedHashSet<String>seen=')" = 1 ]; then
  ok "showYourApps declares ONE seen set, which every row source shares (no duplicate rows)"
else
  no "showYourApps declares seen $(count "$T/sya" 'LinkedHashSet<String>seen=') times -- the row sources no longer share one"
fi

echo "== the row an Off app gets is live (unchanged; the fix relies on it) =="
miss=""
for n in 'VENDING_PKG.equals(pkg)?playStackHolders():java.util.Collections.<String>emptyList();' \
         'if(holders.isEmpty()){heldNote.setVisibility(android.view.View.GONE);chip.setAlpha(1f);chip.setOnClickListener(v->showKeepModeDialog(pkg,sideloaded,paint,preview,onChange));return;}' \
         'Stringm=appMode(pkg);paintModeChip(chip,m);'; do
  has "$T/akr" "$n" || miss="$miss $n"
done
if [ -z "$miss" ]; then
  ok "appKeepRow paints from appMode and opens the picker whenever nothing holds the app, kept or not"
else
  no "appKeepRow lost:$miss"
fi
if has "$T/pmc" '}else{label="Off";'; then
  ok "paintModeChip paints a mode-less app \"Off\""
else
  no "paintModeChip no longer paints a mode-less app \"Off\""
fi
if has "$T/sya" 'Stringmd=modes.get(p);if(md==null)continue;'; then
  ok "the summary skips a mode-less row (an Off row is not counted as kept)"
else
  no "the summary counts mode-less rows"
fi

echo "== switching it back On retires the Off record =="
if has "$T/wam" 'java.util.Set<String>landed=newjava.util.LinkedHashSet<>();' &&
   before "$T/wam" 'dropped.addAll(added);}' 'for(Stringp:added)if(!dropped.contains(p))landed.add(p);'; then
  ok "writeAppModes collects the adds the plan gate let through (landed), after the refusal"
else
  no "writeAppModes does not collect the landed adds after the refusal block"
fi
if before "$T/wam" 'if(!added.isEmpty()&&overPlanNow==null)returnnull;' 'StoreInstaller.writeAtomic(f,sb.toString());' &&
   before "$T/wam" 'StoreInstaller.writeAtomic(f,sb.toString());' 'if(!landed.isEmpty())StoreInstaller.clearTurnedOff(this,landed);' &&
   has "$T/wam" '}catch(Throwableignore){}if(!landed.isEmpty())StoreInstaller.clearTurnedOff(this,landed);returndropped;'; then
  ok "... and retires their Off record only after the keep-set write, in the pass that writes, and only for those adds"
else
  no "writeAppModes does not retire the landed adds' Off record after the keep-set write"
fi
if [ "$CTO" = no ]; then
  no "StoreInstaller.clearTurnedOff is missing -- nothing ever retires an Off record"
else
  miss=""
  for n in 'synchronized(APPKEEP_LOCK){' 'java.util.Set<String>kept=ProfileActivity.keepSetAll(ctx);' \
           's=turnedOffLinesRaw(' \
           'for(Stringp:pkgs)if(kept.contains(p)&&s.remove(p))retired.add(p);' 'if(retired.isEmpty())return;'; do
    has "$T/cto" "$n" || miss="$miss $n"
  done
  if [ -z "$miss" ] && before "$T/cto" 'synchronized(APPKEEP_LOCK){' 'ProfileActivity.keepSetAll(ctx)' &&
     before "$T/cto" 'if(retired.isEmpty())return;' 'writeAtomic('; then
    ok "clearTurnedOff holds APPKEEP_LOCK, re-reads the keep-set from disk, and retires only a package that is kept"
  else
    no "clearTurnedOff lost its lock, its re-read, or its kept-only guard:$miss"
  fi
  if has "$T/ctolit" 'writeAtomic(newFile(ctx.getFilesDir(),"nowhere-appoff.list"),sb.toString());'; then
    ok "... and writes the Off record back atomically"
  else
    no "clearTurnedOff does not write nowhere-appoff.list atomically"
  fi
  if grep -qE '(^|[^A-Za-z0-9_])s\.add(All)?\(' "$T/cto"; then
    no "clearTurnedOff ADDS to the Off record"
  else
    ok "... and never adds to it"
  fi
fi
if before "$T/kai" 'if(present)returntrue;' 'clearTurnedOff(ctx,java.util.Collections.singleton(pkg));' &&
   before "$T/kai" 'if(overPlan)returnfalse;' 'clearTurnedOff(ctx,java.util.Collections.singleton(pkg));' &&
   before "$T/kai" 'writeAtomic(f,sb.toString());' 'clearTurnedOff(ctx,java.util.Collections.singleton(pkg));'; then
  ok "keepAutoImpl (the nApps store add) retires the Off record only after it wrote a NEW keep line"
else
  no "keepAutoImpl does not retire the Off record after its own write"
fi

echo "== the Off branch =="
U3='if(m.get(pkg)==null&&!GMS_PKG.equals(pkg)&&!GSF_PKG.equals(pkg)&&!VENDING_PKG.equals(pkg)&&readPlayDeps(this).contains(pkg)&&readPlaySeen(this).get(pkg)==null)notePlaySeen(this,pkg,true);'
if before "$T/sam" "$U3" 'if(m.get(pkg)==null)setPlayDep(pkg,false);'; then
  ok "an Off keeps an undetermined Play client's fact in playseen BEFORE setPlayDep erases it (stack members excluded)"
else
  no "the Off branch does not record the Play-client fact before setPlayDep(pkg, false)"
fi
if has "$T/sam" 'if(preKept.contains(pkg)&&m.get(pkg)==null){recordTurnedOff(pkg);'; then
  ok "the Off branch still records the Off"
else
  no "the Off branch no longer records the Off"
fi

echo "== what the retirement relies on elsewhere (unchanged) =="
if has "$T/cadoff" 'if(p.isEmpty()||getPackageName().equals(p)||kept.contains(p)||!seen.add(p))continue;'; then
  ok "captureAppDrops never drops a KEPT app that the Off record names"
else
  no "captureAppDrops' Off-record pass lost its kept skip"
fi
if before "$T/dec" 'elseif(ProfileActivity.explicitlyTurnedOff(ctx).contains(pkg)){' 'elseif(returning&&StoreInstaller.keepSetHas(ctx,pkg)){'; then
  ok "AppInstallReceiver.decide checks the Off record before its returning-app reset (so it never keeps an Off app)"
else
  no "AppInstallReceiver.decide lost its Off-record branch, or it moved below the returning-app reset"
fi
if grep -qxF '    grep -xF -f "$APPOFF" "$APPDROP" > "$DROPOFF" 2>/dev/null || :' "$ROAMD" &&
   grep -qxF '  APPOFF="$USERDIR/com.nowhere.chooser/files/nowhere-appoff.list"' "$ROAMD" &&
   grep -qxF '  APPKEEP="$USERDIR/com.nowhere.chooser/files/nowhere-appkeep"' "$ROAMD"; then
  ok "roamd's code-side drop is still the Off record intersected with the drop list"
else
  no "roamd's code-side drop no longer intersects the drop list with the Off record"
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted; the correct-code probes must NOT) =="
  M=$(mktemp -d)
  # probe <convict|pass> <label> <python-on-s> [which]   which = SUT (default) | ST | AIR | ROAMD
  #   Each edit is r(old, new): a missing anchor stops the probe as BROKEN, so a half-applied mutant is never
  #   counted. An edit that changes nothing is INERT, never a conviction.
  probe(){
    local expect="$1" label="$2" py="$3" which="${4:-SUT}" src out rc
    [ -n "$PY" ] || { no "PROBE UNRUN (no python): $label"; return; }
    case "$which" in SUT) src="$SUT";; ST) src="$ST";; AIR) src="$AIR";; ROAMD) src="$ROAMD";; esac
    out="$M/$which.src"
    if ! "$PY" -c "
import io,sys
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
def r(a,b):
    global s
    if s.count(a)!=1: sys.exit('anchor found %d times: %s' % (s.count(a), a[:70]))
    s=s.replace(a,b,1)
$py
io.open(out,'w',encoding='utf-8',newline='').write(s)
" "$src" "$out"; then no "PROBE BROKEN: $label"; return; fi
    if cmp -s "$src" "$out"; then no "PROBE INERT: $label"; return; fi
    case "$which" in
      SUT)   bash "$0" "$out" >/dev/null 2>&1; rc=$? ;;
      ST)    OFFROW_ST="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
      AIR)   OFFROW_AIR="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
      ROAMD) OFFROW_ROAMD="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
    esac
    case "$expect:$rc" in
      convict:0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
      convict:2) no "PROBE BROKEN: $label -- extraction failed on the edited file, that is not a conviction" ;;
      convict:*) ok "convicted: $label" ;;
      pass:0)    ok "not fooled: $label" ;;
      pass:*)    no "UNSOUND: $label -- the suite fails on CORRECT code (rc=$rc)" ;;
    esac
  }
  mutate(){ probe convict "$@"; }
  sound(){ probe pass "$@"; }
  OFFRES="                    if (isBundledSystem(pm, p)) continue;\n                    try {\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));"
  mutate "Play Store no longer listed by name (an auto-pulled vending dropped by reconcile vanishes)" \
    "r('                offNow.add(VENDING_PKG);\n','')"
  mutate "the Off pass resolves with MATCH_ANY_USER (a past-session Off held by another user becomes a row)" \
    "r('MATCH_UNINSTALLED_PACKAGES;\n                offNow.add(VENDING_PKG);','MATCH_UNINSTALLED_PACKAGES\n                        | android.content.pm.PackageManager.MATCH_ANY_USER;\n                offNow.add(VENDING_PKG);')"
  mutate "the Off pass takes MATCH_ANY_USER in by reference (offFlags | keptFlags)" \
    "r('MATCH_UNINSTALLED_PACKAGES;\n                offNow.add(VENDING_PKG);','MATCH_UNINSTALLED_PACKAGES | keptFlags;\n                offNow.add(VENDING_PKG);')"
  mutate "the Off pass's flags collapse to 0 (& for |), so no archived placeholder resolves" \
    "r('final long offFlags = android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES\n                        | android.content.pm.PackageManager.MATCH_UNINSTALLED_PACKAGES;','final long offFlags = android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES\n                        & android.content.pm.PackageManager.MATCH_UNINSTALLED_PACKAGES;')"
  mutate "the Off record read outside the lock, apart from the keep-set (an edit can land between the reads)" \
    "r('                    keptNow = readAppKeep();\n                    offNow = explicitlyTurnedOff();\n                }','                    keptNow = readAppKeep();\n                }\n                offNow = explicitlyTurnedOff();')"
  mutate "the keep-set pass re-reads the keep-set instead of the locked snapshot" \
    "r('                for (String p : keptNow) {','                for (String p : readAppKeep()) {')"
  mutate "the Off pass lists a system package this user never got (the FLAG_SYSTEM skip removed)" \
    "r('                        if ((ai.flags & (android.content.pm.ApplicationInfo.FLAG_SYSTEM\n                                | android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0) continue;\n','')"
  mutate "one try around the whole Off loop (one stale Off line ends the pass for every row after it)" \
    "r('                for (String p : offNow) {\n','                try { for (String p : offNow) {\n'); r('$OFFRES','                    if (isBundledSystem(pm, p)) continue;\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));'); r('                        side.put(p, sl);\n                    } catch (Throwable ignore) {}\n                }\n                // NWP-20261012-06: the kept apps first','                        side.put(p, sl);\n                } } catch (Throwable ignore) {}\n                // NWP-20261012-06: the kept apps first')"
  mutate "the catch adds the row anyway (an app that is not on the phone is listed)" \
    "r('                        side.put(p, sl);\n                    } catch (Throwable ignore) {}\n                }\n                // NWP-20261012-06: the kept apps first','                        side.put(p, sl);\n                    } catch (Throwable notHere) { pkgs.add(p); sizes.put(p, 0L); side.put(p, false); }\n                }\n                // NWP-20261012-06: the kept apps first')"
  mutate "the Off pass reads an empty set instead of the Off record (the pre-fix behaviour)" \
    "r('offNow = explicitlyTurnedOff();','offNow = new java.util.LinkedHashSet<String>();')"
  mutate "the Off pass does not share seen (a launcher app switched Off is listed twice)" \
    "r('for (String p : offNow) {\n                    if (getPackageName().equals(p) || !seen.add(p)) continue;','for (String p : offNow) {\n                    if (getPackageName().equals(p)) continue;')"
  mutate "the Off pass lists gms/gsf (a ghost row that could strand every Play client)" \
    "r('if (getPackageName().equals(p) || !seen.add(p)) continue;\n                    if (GMS_PKG.equals(p) || GSF_PKG.equals(p)) continue;\n','if (getPackageName().equals(p) || !seen.add(p)) continue;\n')"
  mutate "the Off pass lists bundled apps" \
    "r('                    if (GMS_PKG.equals(p) || GSF_PKG.equals(p)) continue;\n$OFFRES','                    if (GMS_PKG.equals(p) || GSF_PKG.equals(p)) continue;\n                    try {\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));')"
  mutate "the Off loop moved inside runOnUiThread (PM binder calls on the UI thread)" \
    "i=s.index('                final long offFlags'); j=s.index('                // NWP-20261012-06: the kept apps first'); b=s[i:j]; s=s[:i]+s[j:]; a='            runOnUiThread(() -> {\n                ll.removeView(spin);\n'; k=s.index(a)+len(a); s=s[:k]+b+s[k:]"
  mutate "the Off pass resolves through the int overload (no ApplicationInfoFlags.of(offFlags))" \
    "r('android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags)); // throws unless','(int) offFlags); // throws unless')"
  mutate "an Off row added before PM resolved it (an app uninstalled after its Off is listed)" \
    "r('$OFFRES','                    if (isBundledSystem(pm, p)) continue;\n                    pkgs.add(p);\n                    try {\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));')"
  mutate "the Off loop deleted and its text pasted into a string literal (prose must not satisfy a check)" \
    "i=s.index('                final long offFlags'); j=s.index('                // NWP-20261012-06: the kept apps first'); s=s[:i]+'                android.util.Log.i(\"NowhereChooser\", \"final long offFlags = 0; java.util.LinkedHashSet<String> offNow = explicitlyTurnedOff(); offNow.add(VENDING_PKG); for (String p : offNow) { pkgs.add(p); }\");\n'+s[j:]"
  mutate "landed filled with every add, refused ones included (the NWP-20260825-22 leak shape)" \
    "r('for (String p : added) if (!dropped.contains(p)) landed.add(p);','for (String p : added) landed.add(p);')"
  mutate "the Off record retired above the keep-set write (the add is not on disk yet, so an On never retires it)" \
    "a='        if (!landed.isEmpty()) StoreInstaller.clearTurnedOff(this, landed);\n'; r(a,''); r('        // temp+rename so no reader',a+'        // temp+rename so no reader')"
  mutate "a prefix guard makes the retire call dead (dropped and landed never overlap)" \
    "r('        if (!landed.isEmpty()) StoreInstaller.clearTurnedOff(this, landed);','        if (!dropped.isEmpty()) if (!landed.isEmpty()) StoreInstaller.clearTurnedOff(this, landed);')"
  mutate "the Off record retired for every kept package, not only this write's adds" \
    "r('StoreInstaller.clearTurnedOff(this, landed);','StoreInstaller.clearTurnedOff(this, modes.keySet());')"
  mutate "clearTurnedOff retires a package that is not kept" \
    "r('if (kept.contains(p) && s.remove(p)) retired.add(p);','if (s.remove(p)) retired.add(p);')" ST
  mutate "clearTurnedOff trusts its caller instead of re-reading the keep-set" \
    "r('java.util.Set<String> kept = ProfileActivity.keepSetAll(ctx);','java.util.Set<String> kept = new java.util.HashSet<>(pkgs);')" ST
  mutate "clearTurnedOff drops APPKEEP_LOCK" \
    "r('        if (pkgs == null || pkgs.isEmpty()) return;\n        synchronized (APPKEEP_LOCK) {\n','        if (pkgs == null || pkgs.isEmpty()) return;\n        {\n')" ST
  mutate "clearTurnedOff adds instead of removing" \
    "r('if (kept.contains(p) && s.remove(p)) retired.add(p);','if (kept.contains(p) && s.add(p)) retired.add(p);')" ST
  mutate "clearTurnedOff writes the keep-set instead of the Off record" \
    "r('writeAtomic(new File(ctx.getFilesDir(), \"nowhere-appoff.list\"), sb.toString());\n                Log.i','writeAtomic(new File(ctx.getFilesDir(), \"nowhere-appkeep\"), sb.toString());\n                Log.i')" ST
  mutate "keepAutoImpl retires the Off record before checking for an existing line (no write happened)" \
    "a='                clearTurnedOff(ctx, java.util.Collections.singleton(pkg)); // NWP-20260926-01: a store add is a re-keep\n'; r(a,''); r('                if (present) return true;',a+'                if (present) return true;')" ST
  mutate "keepAutoImpl no longer retires the Off record" \
    "r('                clearTurnedOff(ctx, java.util.Collections.singleton(pkg)); // NWP-20260926-01: a store add is a re-keep\n','')" ST
  mutate "the Play-client fact is no longer kept across the Off" \
    "r('        if (m.get(pkg) == null && !GMS_PKG.equals(pkg) && !GSF_PKG.equals(pkg) && !VENDING_PKG.equals(pkg)\n                && readPlayDeps(this).contains(pkg) && readPlaySeen(this).get(pkg) == null) notePlaySeen(this, pkg, true);\n','')"
  mutate "the Play-client fact recorded AFTER setPlayDep erased it (it never fires)" \
    "a='        if (m.get(pkg) == null && !GMS_PKG.equals(pkg) && !GSF_PKG.equals(pkg) && !VENDING_PKG.equals(pkg)\n                && readPlayDeps(this).contains(pkg) && readPlaySeen(this).get(pkg) == null) notePlaySeen(this, pkg, true);\n'; r(a,''); b='        if (m.get(pkg) == null) setPlayDep(pkg, false); // removed from the keep-set -> no longer a client\n'; r(b,b+a)"
  mutate "the Play-client fact recorded for Play Store itself (a stack member is reconcile's, never a client)" \
    "r(' && !VENDING_PKG.equals(pkg)\n                && readPlayDeps(this)','\n                && readPlayDeps(this)')"
  mutate "the Off branch stops recording the Off" \
    "r('        if (preKept.contains(pkg) && m.get(pkg) == null) {\n            recordTurnedOff(pkg);\n','        if (preKept.contains(pkg) && m.get(pkg) == null) {\n')"
  mutate "the picker offered only to kept rows (an Off row is shown but cannot be switched back)" \
    "r('            if (holders.isEmpty()) {\n                heldNote','            if (holders.isEmpty() && appMode(pkg) != null) {\n                heldNote')"
  mutate "the picker's listener guarded by the mode (an Off row paints Off and cannot be tapped)" \
    "r('                chip.setOnClickListener(v -> showKeepModeDialog(pkg, sideloaded, paint, preview, onChange));\n                return;','                if (appMode(pkg) != null) chip.setOnClickListener(v -> showKeepModeDialog(pkg, sideloaded, paint, preview, onChange));\n                return;')"
  mutate "a mode-less chip no longer reads Off" \
    "r('label = \"Off\"; fg = MUTED','label = \"\"; fg = MUTED')"
  mutate "the summary counts Off rows as kept" \
    "r('                        if (md == null) continue;\n','')"
  mutate "captureAppDrops drops a kept app the Off record still names (the explicit-Off pass only)" \
    "r('            for (String p : explicitOff) {\n                if (p.isEmpty() || getPackageName().equals(p) || kept.contains(p) || !seen.add(p)) continue;','            for (String p : explicitOff) {\n                if (p.isEmpty() || getPackageName().equals(p) || !seen.add(p)) continue;')"
  mutate "AppInstallReceiver resets a returning app before checking the Off record" \
    "a='        } else if (ProfileActivity.explicitlyTurnedOff(ctx).contains(pkg)) {\n            outcome = \"not kept (the user switched this app off)\";\n'; r(a,''); b='            outcome = wrote ? \"re-installed -- reset to this bucket\\'s default\" : \"refused by keepInMode\";\n'; r(b,b+a)" AIR
  mutate "roamd drops code for everything on the drop list, not only the Off record" \
    "r('grep -xF -f \"\$APPOFF\" \"\$APPDROP\" > \"\$DROPOFF\" 2>/dev/null || :','cp \"\$APPDROP\" \"\$DROPOFF\" 2>/dev/null || :')" ROAMD
  sound "MATCH_ANY_USER named in a comment inside the Off pass (prose is not code)" \
    "r('$OFFRES','                    if (isBundledSystem(pm, p)) continue; // never MATCH_ANY_USER here\n                    try {\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));')"
  sound "the Off pass reformatted across lines (whitespace is not code)" \
    "r('                    if (GMS_PKG.equals(p) || GSF_PKG.equals(p)) continue;\n$OFFRES','                    if (GMS_PKG.equals(p)\n                            || GSF_PKG.equals(p))\n                        continue;\n                    if (isBundledSystem(pm,\n                            p)) continue;\n                    try {\n                        android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p,\n                                android.content.pm.PackageManager.ApplicationInfoFlags.of(offFlags));')"
  sound "a } inside a string literal in the Off pass (the brace match sees through literals)" \
    "r('!= 0) continue;\n                        pkgs.add(p);\n','!= 0) continue;\n                        pkgs.add(p);\n                        android.util.Log.v(\"NowhereChooser\", \"} off row\");\n')"
  sound "clearTurnedOff moved above recordTurnedOff (extraction follows braces, not neighbours)" \
    "i=s.index('    /** NWP-20260926-01: the inverse of recordTurnedOff'); j=s.index('    /** The packages positively observed present this session'); b=s[i:j]; s=s[:i]+s[j:]; k=s.index('    /** NWP-20260904-07: static twin of ProfileActivity.recordTurnedOff.'); s=s[:k]+b+s[k:]" ST
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
