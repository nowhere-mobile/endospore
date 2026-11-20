#!/usr/bin/env bash
# test-call-relay-spike-java.sh [--mutate] -- NWP-20261210-11: the debug-only R0 call-relay spike verb
# (docs/call-relay.md section 14, row R0).
#
# WHY. R0 runs the lynx spike's steps from the chooser, a platform-signed app holding CALL_AUDIO_INTERCEPTION, and tries
# MODE_CALL_REDIRECT (5) then MODE_CALL_SCREENING (4). The verb answers a call and takes its audio, so it must do
# nothing on a user build: CallRelaySpikeReceiver refuses it unless ro.debuggable is exactly "1", and the receiver is
# not exported and has no intent-filter. Its logs carry modes, counts and levels only, never a number or a caller.
#
# WHAT RUNS. CallRelaySpike (pure Java) is compiled with tests/call-relay-spike/CallRelaySpikeCases.java ALONE and RUN:
# (A1) allowed("1"); (A2) "0", "", null, "true", " 1", "1 " refused; (M1) null, "", "2,3,x" give {5,4}; (M2) "4" gives
# {4}, "5,4,5" {5,4}, "4,5" {4,5}; (C1) clampSecs 0 -> 20, 1 -> 5, 999 -> 60; (D1) silence is -120.0, a full-scale
# square ~0.0, an amp-0.5 sine ~-9.0; (T1) the stereo tone's channels are equal and its peak is within amp*32767;
# (L1) every line builder matches a fixed regex of digits, '-', '.' and fixed tokens, in three default locales.
# Pins on comment-stripped sources: (P1) the allowed( guard is onReceive's first statement and precedes every
# getSystemService, extra read, new Thread, acceptRingingCall, setMode, getCallDownlink and getCallUplink in the file,
# and nothing calls goAsync or holds a PendingResult; (P2) the manifest receiver is exported="false" with no
# intent-filter; (P3) the three uses-permission are present; (P4) the receiver holds none of the number/caller tokens
# and names neither NowhereCallControlService nor RejectedCallSealReceiver; (P5) a finally block holds
# setMicrophoneMute(false) and setMode(AudioManager.MODE_NORMAL), and nothing calls setMode(priorMode).
#
# What this does NOT prove: that the platform grants CALL_AUDIO_INTERCEPTION, that either mode holds or silences the
# earpiece, or that capture and injection work from the app. That is the human device run on lynx userdebug, the
# merger's follow-up (the procedure is in CallRelaySpike's header). The merger's full javac / `m NowhereChooser` covers
# CallRelaySpikeReceiver itself.
#
#   bash test-call-relay-spike-java.sh              # the cases and the pins
#   bash test-call-relay-spike-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; fi
done

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-call-relay-spike-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

SP="$SRC/CallRelaySpike.java"; RC="$SRC/CallRelaySpikeReceiver.java"; MAN="$HERE/AndroidManifest.xml"
CASES="$HERE/tests/call-relay-spike/CallRelaySpikeCases.java"

cases() { # cases <CallRelaySpike.java> [quiet]: 0 pass, 1 a case failed (or a file is missing), 2 did not compile
  local sp=$1 quiet=${2:-} cls out rc=0
  if [ ! -f "$sp" ] || [ ! -f "$CASES" ]; then
    [ -z "$quiet" ] && echo "FAIL A1-L1 $sp or $CASES is missing"
    return 1
  fi
  cls=$(mktemp -d -p "$W") || return 2
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$sp" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.CallRelaySpikeCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <CallRelaySpikeReceiver.java> <AndroidManifest.xml>: 0 hold, 1 failed, 2 extract
  python3 - "$1" "$2" <<'PY'
import io, os, re, sys
rc_path, man_path = sys.argv[1:3]

def strip(s):
    """Drop // and /* */ comments; string and char literals are kept."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def skip_lit(s, i):
    c = s[i]
    if c != '"' and c != "'":
        return i
    j = i + 1
    while j < len(s) and s[j] != c:
        j += 2 if s[j] == '\\' else 1
    return j + 1

def block(s, at):
    """(start, end) of the brace block that opens at the first '{' at or after `at`; literals are skipped."""
    k = at
    while k < len(s) and s[k] != '{':
        nk = skip_lit(s, k)
        k = nk if nk != k else k + 1
    if k >= len(s):
        return None
    j, d = k, 0
    while k < len(s):
        nk = skip_lit(s, k)
        if nk != k:
            k = nk; continue
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: return j, k + 1
        k += 1
    return None

bad = []

# P1, P4, P5: the receiver
if not os.path.isfile(rc_path):
    for p in ('P1', 'P4', 'P5'):
        bad.append('%s %s is missing' % (p, rc_path))
else:
    src = strip(io.open(rc_path, encoding='utf-8').read())
    SIG = 'public void onReceive(Context ctx, Intent intent)'
    GUARD = ('if (!CallRelaySpike.allowed(sysProp("ro.debuggable", "0"))) '
             '{ Log.i(CallRelaySpike.TAG, CallRelaySpike.REFUSED); return; }')
    at = src.find(SIG)
    b = block(src, at + len(SIG)) if at >= 0 else None
    if b is None:
        print("EXTRACTION FAILED: no '%s' body" % SIG); sys.exit(2)
    body = src[b[0] + 1:b[1]]
    if not ' '.join(body.split()).startswith(' '.join(GUARD.split())):
        bad.append('P1 onReceive does not open with `%s`' % GUARD)
    g = src.find(GUARD, b[0])
    if g < 0:
        bad.append('P1 the guard is missing')
    else:
        for tok in ('getSystemService', 'getStringExtra', 'getIntExtra', 'new Thread', 'acceptRingingCall',
                    'setMode(', 'getCallDownlink', 'getCallUplink'):
            first = src.find(tok)
            if first < 0:
                bad.append('P1 the receiver never calls %s' % tok)
            elif first < g:
                bad.append('P1 %s comes before the ro.debuggable guard' % tok)
    for tok in ('goAsync', 'PendingResult'):
        if tok in src:
            bad.append('P1 the receiver names %s: the run must hold no broadcast result' % tok)
    for tok in ('getHandle', 'getLine1Number', 'EXTRA_INCOMING_NUMBER', 'getCallerDisplayName', 'Call.Details',
                'TelephonyManager', 'NowhereCallControlService', 'RejectedCallSealReceiver'):
        if tok in src:
            bad.append('P4 the receiver names %s' % tok)
    fins = []
    for m in re.finditer(r'\bfinally\b', src):
        fb = block(src, m.end())
        if fb is not None:
            fins.append(src[fb[0]:fb[1]])
    if not any('setMicrophoneMute(false)' in f and 'setMode(AudioManager.MODE_NORMAL)' in f for f in fins):
        bad.append('P5 no finally block holds both setMicrophoneMute(false) and setMode(AudioManager.MODE_NORMAL)')
    if re.search(r'setMode\(\s*priorMode\s*\)', src):
        bad.append('P5 the receiver restores setMode(priorMode)')

# P2, P3: the manifest
man = re.sub(r'<!--.*?-->', '', io.open(man_path, encoding='utf-8').read(), flags=re.S)
els = list(re.finditer(r'<receiver\b[^>]*?android:name="\.CallRelaySpikeReceiver"[^>]*?(/?)>', man, flags=re.S))
if len(els) != 1:
    bad.append('P2 %d .CallRelaySpikeReceiver receivers in the manifest, want 1' % len(els))
else:
    e = els[0]
    if 'android:exported="false"' not in e.group(0):
        bad.append('P2 the receiver is not android:exported="false"')
    if e.group(1) != '/':
        end = man.find('</receiver>', e.end())
        inner = man[e.end():end if end >= 0 else len(man)]
        if '<intent-filter' in inner:
            bad.append('P2 the receiver has an intent-filter')
for perm in ('CALL_AUDIO_INTERCEPTION', 'MODIFY_AUDIO_SETTINGS', 'RECORD_AUDIO'):
    if not re.search(r'<uses-permission\s+android:name="android\.permission\.%s"\s*/>' % perm, man):
        bad.append('P3 no <uses-permission> for android.permission.%s' % perm)

for x in bad: print('PIN FAILED: ' + x)
if not bad: print('ok P1-P5 the guard comes first, the receiver is unexported with no intent-filter, the three '
                  'permissions are declared, no caller token is read, and the finally unmutes and drops the mode')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <CallRelaySpike.java> <CallRelaySpikeReceiver.java> <AndroidManifest.xml> [quiet]
  local sp=$1 rc=$2 man=$3 quiet=${4:-} crc=0 prc=0 pout
  cases "$sp" "$quiet" || crc=$?
  [ "$crc" -eq 2 ] && return 2
  pout=$(pins "$rc" "$man" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$crc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$SP" "$RC" "$MAN"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-call-relay-spike-java: FAIL (rc $rc)"; exit 1; fi
echo "test-call-relay-spike-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: sp|rc|man> <python-regex> <replacement> [want: convicted|survives]
  local name=$1 which=$2 pat=$3 rep=$4 want=${5:-convicted} d src orig msp mrc mman rc=0
  d=$(mktemp -d -p "$W") || { fails=$((fails + 1)); return; }
  msp="$d/CallRelaySpike.java"; mrc="$d/CallRelaySpikeReceiver.java"; mman="$d/AndroidManifest.xml"
  cp "$SP" "$msp"; cp "$RC" "$mrc"; cp "$MAN" "$mman"
  case "$which" in
    sp) src=$msp; orig=$SP ;;
    rc) src=$mrc; orig=$RC ;;
    man) src=$mman; orig=$MAN ;;
    *) echo "  $name: ⚠ unknown file '$which'"; fails=$((fails + 1)); rm -rf "$d"; return ;;
  esac
  python3 - "$src" "$pat" "$rep" <<'PY'
import io, re, sys
p, pat, rep = sys.argv[1:4]
s = io.open(p, encoding='utf-8').read()
io.open(p, 'w', encoding='utf-8').write(re.sub(pat, rep, s, count=1, flags=re.S))
PY
  if cmp -s "$src" "$orig"; then
    echo "  $name: ⚠ NOT APPLIED"; fails=$((fails + 1)); rm -rf "$d"; return
  fi
  suite "$msp" "$mrc" "$mman" quiet; rc=$?
  if [ "$want" = survives ]; then
    if [ "$rc" -eq 0 ]; then echo "  $name: survives (control)"
    else echo "  $name: ⚠ the control FAILED the suite (rc $rc)"; fails=$((fails + 1)); fi
  elif [ "$rc" -eq 1 ]; then echo "  $name: convicted"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

G='if \(!CallRelaySpike\.allowed\(sysProp\("ro\.debuggable", "0"\)\)\) \{ Log\.i\(CallRelaySpike\.TAG, CallRelaySpike\.REFUSED\); return; \}\n\s*'
echo "mutants:"
mutant "X1 allowed accepts any non-empty value (A2)" sp 'return "1"\.equals\(debuggable\);' 'return debuggable != null && !debuggable.isEmpty();'
mutant "X2 the guard moved after acceptRingingCall (P1)" rc "$G(.*?tm\.acceptRingingCall\(\);)" '\1 if (!CallRelaySpike.allowed(sysProp("ro.debuggable", "0"))) { log(CallRelaySpike.REFUSED); return; }'
mutant "X3 the guard removed (P1)" rc "$G" ''
mutant "X4 the receiver exported (P2)" man '(android:name="\.CallRelaySpikeReceiver" android:exported=)"false"' '\1"true"'
mutant "X5 an intent-filter added (P2)" man '(<receiver android:name="\.CallRelaySpikeReceiver" android:exported="false")/>' '\1><intent-filter><action android:name="com.nowhere.chooser.SPIKE"/></intent-filter></receiver>'
mutant "X6 CALL_AUDIO_INTERCEPTION dropped (P3)" man '\s*<uses-permission android:name="android\.permission\.CALL_AUDIO_INTERCEPTION"/>' ''
mutant "X7 parseModes keeps 2 (M1)" sp 'if \(m != MODE_CALL_SCREENING && m != MODE_CALL_REDIRECT\) continue;' 'if (m != 2 && m != MODE_CALL_SCREENING && m != MODE_CALL_REDIRECT) continue;'
mutant "X8 the default is {4,5} (M1)" sp 'new int\[\] \{MODE_CALL_REDIRECT, MODE_CALL_SCREENING\}' 'new int[] {MODE_CALL_SCREENING, MODE_CALL_REDIRECT}'
mutant "X9 the dbfs floor removed (D1)" sp 'if \(rms <= 0\) return FLOOR_DBFS;\s*double db = 20\.0 \* Math\.log10\(rms / FULL_SCALE\);\s*return db < FLOOR_DBFS \? FLOOR_DBFS : db;' 'return 20.0 * Math.log10(rms / FULL_SCALE);'
mutant "X10 a getHandle( call added (P4)" rc '(log\(CallRelaySpike\.ANSWERED\);)' '\1 Object h = tm.getCallCapablePhoneAccounts().isEmpty() ? null : tm.getCallCapablePhoneAccounts().get(0).getHandle();'
mutant "X11 the mute restore removed (P5)" rc 'try \{ am\.setMicrophoneMute\(false\); \} catch \(Throwable e\) \{ log\(CallRelaySpike\.errLine\("unmute", cls\(e\)\)\); \}' ''
mutant "C0 a comment edit (control)" rc '(\* NWP-20261210-11: the debug-only R0 call-relay spike verb)' '\1 (control edit)' survives

if [ "$fails" -ne 0 ]; then echo "test-call-relay-spike-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-call-relay-spike-java: all mutants convicted, the control survives"
