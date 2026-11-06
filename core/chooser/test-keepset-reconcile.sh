#!/usr/bin/env bash
# test-keepset-reconcile.sh [<ProfileActivity.java>] [--mutate] -- the login-time phantom reconcile prunes
# ONLY a keep line that is absent from PM AND absent from the #apps head, and prunes NOTHING when it cannot
# tell.
#
# WHY THIS IS COMMITTED. NWP-20260904-06 stops NEW phantom keep lines by recording the PACKAGE_REMOVED
# transition, but a transition that happened in a PAST session was never observed by anyone, so a phantom
# already in the field (odtest40, lynx, 2026-09-04) outlives that fix forever: "Not saved yet: <app>" on every
# visit, no roam clears it. This reconcile runs from the post-login sweep and clears it -- and the danger is
# entirely in how it decides, because the keep-set is the ONE file that says what the user chose to roam.
#
# THE PREDICATE IS TWO ABSENCES AND EACH ONE ALONE IS WRONG:
#   * !pmKnows       -- alone, it would prune an app whose #apps seal REFUSED last logoff while the app is still
#                       installed? No: pmKnows is TRUE for that one. What it would prune alone is anything
#                       PM has not raised yet -- so the second absence is required.
#   * not in #apps   -- alone, it would prune every INSTALLED app whose code was never sealed (an app installed
#                       this session before its first logoff). So the first absence is required.
#   Together: gone from the phone AND nothing in the store to restore it from. That, and only that, is a phantom.
#
# AND "CANNOT TELL" MUST MEAN "PRUNE NOTHING". SEAL-DELTA's StoredApps is a cold single-flight cache right after
# login, so a reply without storedMeasured is "unknown", never "none"; a daemon that does not answer is
# "unknown"; a throwaway session has no store at all. Every one of those must leave the keep-set alone --
# losing the fix costs one more login, losing a user's choice costs their app.
#
#   bash test-keepset-reconcile.sh            # the invariants
#   bash test-keepset-reconcile.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Source-level checks on FUNCTIONAL forms (never comment text), same committed style as
# test-keepset-uninstall.sh -- the chooser has no unit-test harness. The three sibling files are taken from
# the SUT's directory, or from RECON_US / RECON_DS / RECON_ST so a mutation can target them too.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
US="${RECON_US:-$HERE/src/com/nowhere/chooser/UnarchiveService.java}"
DS="${RECON_DS:-$HERE/src/com/nowhere/chooser/DaemonSocket.java}"
ST="${RECON_ST:-$HERE/src/com/nowhere/chooser/StoreInstaller.java}"
for f in "$US" "$DS" "$ST"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

body(){ awk "/$1/,/$2/" "$3"; }
RC=$(body 'static void reconcilePhantomKeepLines\(' 'static java.util.Set<String> keepSetAll\(' "$SUT")
SWEEP=$(body 'Thread sw = new Thread\(\(\) -> \{' 'try \{ sweepAutoJoined\(byHand\); \}' "$US")
LEN=$(body 'static String\[\] lenReply\(String msg, int readCapMs\) \{' 'static String roundTrip\(String msg, int readCapMs\) \{' "$DS")
RKL=$(body 'static void removeKeepLines\(Context ctx, java.util.Set<String> drop\) \{' 'static void recordTurnedOff\(Context ctx, String pkg\) \{' "$ST")
[ -n "$RC" ] && [ -n "$SWEEP" ] && [ -n "$LEN" ] && [ -n "$RKL" ] || { echo "EXTRACTION FAILED -- a method anchor moved" >&2; exit 2; }

echo "== both absences are required =="
if grep -q 'if (!pmKnows(pm, pkg)) absent.add(pkg);' <<<"$RC"; then
  ok "only a package PM cannot see (installed, archived, any user) is a candidate"
else
  no "the PM gate is gone -- an installed app whose code was never sealed would be pruned"
fi
if grep -q 'for (String pkg : absent) if (!stored.contains(pkg) && !pmKnows(pm, pkg)) drop.add(pkg);' <<<"$RC"; then
  ok "... and only if the #apps head holds no code for it -- with PM asked AGAIN at drop time (the poll may have waited ~30 s)"
else
  no "the store gate is gone -- an un-materialised on-demand app (absent from PM, code in #apps) would be pruned"
fi

echo "== cannot-tell prunes nothing =="
if grep -q 'if (o.optBoolean("storedMeasured", false)) {' <<<"$RC"; then
  ok "the store answer counts only when the daemon says it is MEASURED"
else
  no "an unmeasured (cold-cache) reply is read as 'nothing stored' -- every absent line would be pruned on the first poll"
fi
if grep -q 'if (stored == null) {' <<<"$RC" && grep -A3 'if (stored == null) {' <<<"$RC" | grep -c 'return;' >/dev/null; then
  ok "never measured within the poll budget -> return without touching the keep-set"
else
  no "the never-measured case falls through to the prune"
fi
if grep -q 'if ("local".equals(o.optString("session"))) return;' <<<"$RC"; then
  ok "a throwaway session (no store) is left alone"
else
  no "a throwaway session is reconciled against a store it does not have"
fi
if grep -q 'DaemonSocket.lenReply("SEAL-DELTA"' <<<"$RC"; then
  ok "the reply is read length-framed (roundTrip would truncate the JSON to its first line)"
else
  no "SEAL-DELTA is not read through the length-framed reader"
fi
if grep -q 'if (off < n) return new String\[\]{hl, null};' <<<"$LEN"; then
  ok "lenReply: a short body is null (unknown), never a partial string that parses as something"
else
  no "lenReply returns a truncated body -- a partial JSON could parse as a smaller storedApps"
fi
if grep -q 'if (h.length < 2 || !"OK".equals(h\[0\])) return new String\[\]{hl, null};' <<<"$LEN"; then
  ok "lenReply: a non-OK header (NONE / ERR) is null, not a body"
else
  no "lenReply reads a body after a non-OK header"
fi

echo "== the exclusions the logoff prune has =="
if grep -q 'if (GMS_PKG.equals(pkg) || GSF_PKG.equals(pkg) || ctx.getPackageName().equals(pkg)) continue;' <<<"$RC"; then
  ok "gms / gsf / the chooser itself are never candidates"
else
  no "the play-stack and self exclusions are missing"
fi
if grep -q 'if (isBundledSystem(pm, pkg)) continue;' <<<"$RC"; then
  ok "a bundled app is not this path's business (its data IS the profile; the logoff prune owns that drop)"
else
  no "a bundled app can be recorded as turned off -- the data-loss shape NWP-20260825-22 names"
fi

echo "== what a prune records, and where it runs =="
if grep -q 'for (String pkg : drop) StoreInstaller.recordTurnedOff(ctx, pkg);' <<<"$RC" \
   && grep -q 'StoreInstaller.removeKeepLines(ctx, drop);' <<<"$RC"; then
  ok "a phantom is recorded exactly as the logoff prune records an uninstall (line removed + appoff)"
else
  no "the prune does not record the turn-off, or does not remove the line"
fi
if grep -q 'ProfileActivity.reconcilePhantomKeepLines(app)' <<<"$SWEEP" && grep -q 'final android.content.Context app = getApplicationContext();' <<<"$SWEEP"; then
  ok "it runs from the post-login sweep (placeholders already raised), on the APPLICATION context (the service may stop first)"
else
  no "nothing calls the reconcile from the sweep -- the phantom in the field stays"
fi
if grep -q 'sb.append(ln).append((char) 10);' <<<"$RKL" && grep -q 'if (drop.contains(ln.split("\\t", 2)\[0\].trim())) continue;' <<<"$RKL"; then
  ok "the shared removeKeepLines re-emits survivors verbatim (tokens and all) and matches on the package only"
else
  no "the shared removeKeepLines round-trips survivors or matches on more than the package"
fi
if grep -q 'StoreInstaller.removeKeepLines(this, drop);' "$SUT" && grep -q 'StoreInstaller.recordTurnedOff(this, pkg);' "$SUT"; then
  ok "the logoff prune delegates to the same two implementations (no drift between the two prunes)"
else
  no "the logoff prune has its own copy -- the two prunes can drift"
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  [ -n "$PY" ] || echo "  SKIP  mutations: no working python on PATH" >&2
  # mutate <label> <python-on-s> [which]   which = SUT (default) | US | DS
  mutate(){
    [ -n "$PY" ] || { no "MUTATION UNRUN (no python): $1"; return; }
    local which="${3:-SUT}" src out
    case "$which" in SUT) src="$SUT";; US) src="$US";; DS) src="$DS";; esac
    out="$M/$which.java"
    if ! "$PY" -c "
import io,sys,re
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
$2
io.open(out,'w',encoding='utf-8',newline=chr(10)).write(s)
" "$src" "$out"; then no "MUTATION BROKEN: $1"; return; fi
    if cmp -s "$src" "$out"; then no "MUTATION INERT: $1"; return; fi
    local rc
    case "$which" in
      SUT) bash "$0" "$out" >/dev/null 2>&1; rc=$? ;;
      US)  RECON_US="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
      DS)  RECON_DS="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
    esac
    if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the PM gate is dropped (every keep line is a candidate)" \
    "s=s.replace('if (!pmKnows(pm, pkg)) absent.add(pkg);','absent.add(pkg);',1)"
  mutate "the store gate is dropped (absent from PM alone prunes -- kills un-materialised on-demand opt-ins)" \
    "s=s.replace('for (String pkg : absent) if (!stored.contains(pkg) && !pmKnows(pm, pkg)) drop.add(pkg);','for (String pkg : absent) if (!pmKnows(pm, pkg)) drop.add(pkg);',1)"
  mutate "the drop-time PM re-check is dropped (a reinstall during the poll wait is turned Off)" \
    "s=s.replace('for (String pkg : absent) if (!stored.contains(pkg) && !pmKnows(pm, pkg)) drop.add(pkg);','for (String pkg : absent) if (!stored.contains(pkg)) drop.add(pkg);',1)"
  mutate "an unmeasured reply is read as measured-empty" \
    "s=s.replace('if (o.optBoolean(\"storedMeasured\", false)) {','if (true) {',1)"
  mutate "never-measured falls through to the prune with an empty store set" \
    "s=re.sub(r'if \(stored == null\) \{\s*android\.util\.Log\.i\([^;]*;\s*return;\s*\}', 'if (stored == null) stored = new java.util.HashSet<>();', s, count=1, flags=re.S)"
  mutate "a throwaway session is reconciled anyway" \
    "s=s.replace('if (\"local\".equals(o.optString(\"session\"))) return; // a throwaway has no store: nothing is phantom','',1)"
  mutate "the sweep no longer calls the reconcile" \
    "s=s.replace('Thread rc = new Thread(() -> ProfileActivity.reconcilePhantomKeepLines(app), \"nowhere-phantom-reconcile\");','Thread rc = new Thread(() -> {}, \"nowhere-phantom-reconcile\");',1)" US
  mutate "lenReply hands back a truncated body" \
    "s=s.replace('if (off < n) return new String[]{hl, null};','',1)" DS
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
