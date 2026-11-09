#!/usr/bin/env bash
# test-daemon-verb-readers.sh [<src-dir>] [--mutate] -- NWP-20261027-10: a verb that any chooser site reads
# multi-line is read multi-line at EVERY chooser site.
#
# WHY THIS IS COMMITTED. DaemonSocket.roundTrip returns the FIRST reply line and nothing else. Twice that
# shipped as a silent production no-op: GET-BINDINGS read with the one-line helper showed every SIM as not
# bound, and the #176 outbound lock did nothing. NWP-20261011-63 made a one-line read LOG when more lines are
# already buffered (DaemonSocket.moreBuffered), but that is a non-blocking ready(): on a loaded phone the second
# line lands after the first readLine returns and the read is silent again. The GET-SEAL-BLIND regression
# (fixed by NWP-20261006-23) was exactly that shape: read with the one-line sendDaemon, so the refused-logoff
# dialog never named the blocking app. A new screen reaches for sendDaemon because it is the default helper;
# nothing failed when it did. Backlog row: "`DaemonSocket.roundTrip` silently truncates every reply to its first
# line" (§B).
#
# WHAT IT SCANS. Chooser SOURCE only (src/com/nowhere/chooser/*.java, or the directory given as an argument), no
# javac. Comments are dropped first (chooser comments quote calls such as sendDaemon("GET-BINDINGS\n")).
# Every method that sends a request and reads the reply is classified by what it returns:
#   ONE_LINE  the first reply line (DaemonSocket.roundTrip and the per-file wrappers around it)
#   MULTI     every line, or a length-framed body (roundTripLines*, lenReply and their wrappers)
#   INLINE    opens DaemonSocket.connect() and reads a fixed verb itself
# A call's VERB is the text after the opening quote of its first argument, up to the first \n or the closing
# quote (daemonCmd("GET-OTA-TIME") has no \n). A call is matched with a word boundary and its own file, so
# readLine( is never StoreService line( and DaemonSocket.lenReply( is never StoreService lenReply(.
#
# RULES (a finding prints as `File:line VERB helper rule <x>`):
#   i    a ONE_LINE call names a KNOWN_MULTI verb and the site is not pinned in ARG_DEPENDENT
#   ii   a MULTI call names a verb that is not in KNOWN_MULTI -- a new multi-line verb is added there on purpose,
#        which is what makes rule i cover it
#   iii  a helper call whose first argument is not a literal and whose File:method is not in NONLITERAL, so the
#        scan is never silently blind to a variable-built request. A helper's own body (it passes its parameter
#        on) is exempt.
#   iv   a method that calls DaemonSocket.connect() is in none of ONE_LINE, MULTI or INLINE. A method that only
#        calls the DaemonSocket helpers is a CALLER, checked call by call under i-iii, not a reader to classify.
#   v    an ARG_DEPENDENT, INLINE, NONLITERAL or helper pin no longer matches anything in the sources, so a stale
#        pin cannot pile up
# ARG_DEPENDENT carries the COUNT of one-line calls of the verb in that method. The exemption holds only while
# the count equals the pin: REPORT-ISSUE is read one-line by the SEND and multi-line by the PREVIEW in the same
# method, so a preview turned into sendDaemon (count 2) is a rule-i finding, not an exempt site.
# CONTROLS: at least one ONE_LINE call, one MULTI call, and roundTripLines("GET-BINDINGS must be found, so
# "no findings" can never mean "no input".
#
# LIMITS. Line-wise: a helper name split from its ( by a newline is missed (none exists). The scan cannot see the
# daemon side: a verb whose daemon reply is multi-line but which NO chooser site reads multi-line is not in
# KNOWN_MULTI and is still caught only by moreBuffered's best effort.
#
#   bash test-daemon-verb-readers.sh            # the scan
#   bash test-daemon-verb-readers.sh --mutate   # ... plus mutants that must each CONVICT the suite
#   bash test-daemon-verb-readers.sh <dir>      # scan another copy of the sources
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src/com/nowhere/chooser"; MUTATE=0
for a in "$@"; do case $a in --mutate) MUTATE=1 ;; *) SRC=$a ;; esac; done
[ -d "$SRC" ] || { echo "no such directory: $SRC" >&2; exit 2; }

# name File. DaemonSocket helpers match the qualified form DaemonSocket.<name>( in every file; every other
# helper is private and matches unqualified, in its own file only.
export ONE_LINE='roundTrip DaemonSocket
sendDaemon ChooserActivity
daemonCmd ChooserActivity
pollDaemon ChooserActivity
sendDaemon ProfileActivity
sendDaemonReply ProfileActivity
line StoreService
daemon UnarchiveService
send WifiMirror
send GateTrace'
export MULTI='roundTripLines DaemonSocket
roundTripLinesRaw DaemonSocket
roundTripLinesOrNull DaemonSocket
lenReply DaemonSocket
sendDaemonLines ChooserActivity
sendDaemonMulti ProfileActivity
daemonLenReply ProfileActivity
lenReply StoreService
fetchVerdict StoreService'
# File:method VERB shape. Readers that open connect() and write a fixed verb themselves.
export INLINE='ProfileActivity:sendExport EXPORT one-line
ProfileActivity:doLogoffImpl LOGOUT WAIT-lines+one-line
ProfileActivity:sealStatus SEAL-STATUS one-line+conditional-REASON
ChooserActivity:roamInStreaming ROAM-IN streamed
ChooserActivity:createStreaming - streamed # CREATE / CREATE-CODE come from the caller (NWP-20261120-06)
UnarchiveService:daemonMaterialize MATERIALIZE-APP-PROG streamed
NfcFido2:shuttle - apdu-shuttle # the FIDO2-NFC-* verb comes from the caller'
# File:method -> VERB[,VERB]. Helper calls whose first argument is not a literal, resolved by hand.
export NONLITERAL='ChooserActivity:ownerKeyAsync -> OWNER-KEY-NEW,OWNER-KEY-ENSURE # msg = verb + ...
ChooserActivity:changeOwnerPass -> OWNER-KEY-REWRAP # OwnerPassChange.rewrapRequest
ChooserActivity:buildOwnerInboxScreen -> GET-OWNER-INBOX # ownerInboxReq, read with roundTripLinesOrNull
ChooserActivity:buildOwnerInboxItemScreen -> READ-OWNER-ITEM # ownerInboxReq, read with roundTripLines
ChooserActivity:doGateRollback -> ROLLBACK-GATE # gateRollbackRequest
ChooserActivity:refreshCreditLostNotice -> CLEAR-CREDIT-LOST # creditLostClearCommand
ChooserActivity:evictRecheck -> EVICT-RECHECK,EVICT-RECHECK-SAVED # WipeOnSave.recheckVerb
ChooserActivity:maybeMirrorWifi -> WIFI-ADOPT # WifiMirrorLine.adoptRequest
ChooserActivity:saveDeviceName -> SET-DEVICE-LABEL # DeviceName.request, a one-line OK / ERR-ARGS / ERR reply
ChooserActivity:startSyncStatusWatcher -> PREFETCH-ARM,PREFETCH-DISARM,REKEY-WAIT-NET,REKEY-WAIT-WIFI,REKEY-ARM,REKEY-WAIT-BATTERY # ternaries
ProfileActivity:doLogoffImpl -> EXPECT-SHRINK-INFERRED # StringBuilder ip
ProfileActivity:runTieVerb -> SE-TIE,SE-UNTIE # verb parameter
ProfileActivity:addCreditsScreen -> CLAIM,CLAIM2 # PlanChoice.claimRequest
ProfileActivity:showStorage -> REPAIR-WALLET # WalletRepairCopy.CHECK_REQUEST / CONFIRM_REQUEST, one-line replies
ProfileActivity:probeSession -> GET-SESSION-TYPE,GET-OFFLINE,GET-SESSION-NAME,OTA-AFTER-LOGOFF # the Sender ProfileProbe.run asks (the verb comes from ProfileProbe), one-line replies; OTA-STATUS stays a literal roundTripLines
TelArrival:untilAnswered -> SEAL-TEL,SEAL-MMS # telRequest / mmsRequest from SmsDeliverReceiver
UnarchiveService:sweepAuto -> AUTO-SWEEP-APP # SweepOutcome.request, a one-line OK / ERR-ARG reply
SkipNoticeActivity:markShown -> SKIP-NOTICE-SHOWN # SkipNoticeCopy.shownRequest, a one-line OK / ERR reply
GateTrace:ev -> GATE-TRACE # both ev overloads pass a token to send
UnarchiveService:restoreOnlyListLocked -> RESTORE-ODDATA # OdRestoreList.request, a list of 2..CHUNK names, read with roundTripLines: one "<pkg> <reply>" line per app, then END <n> (NWP-20261128-16)'
# VERB File:method COUNT # why the one-line read is correct. COUNT = one-line calls of VERB in that method.
export ARG_DEPENDENT='REPORT-ISSUE ProfileActivity:showReportIssue 1 # the send (reportRequestJson(.., false)) gets one OK <ticket> / ERR-... line; core/agent report_issue.go handleReportIssue writes more only for the preview
REPORT-ISSUE ChooserActivity:buildReportScreen 1 # same: gateReportJson(.., false) is the send; handleReportIssue answers it with one line
GET-OTA-TIME ChooserActivity:otaTimeCheck 1 # core/agent main.go name == "GET-OTA-TIME" writes exactly one line (otaTimeGet(): HH:MM or empty)
GET-OTA-TIME ChooserActivity:onResume 1 # same arm, always one line
GET-OTA-TIME ChooserActivity:showOtaTimePicker 1 # same arm, always one line
FETCH-APP UnarchiveService:tapUpdateLocked 1 # sends no progress opt-in, so core/agent catalog.go handleFetchApp writes exactly one line
REPORT-ISSUE DiagReportJob:sendScheduled 1 # the scheduled send (preview false) gets one OK <ticket> / ERR-... line; core/agent report_issue.go handleReportIssue writes more only for the preview
RESTORE-ODDATA AppInstallReceiver:heal 1 # the one-name form answers one line (core/agent app_code.go handleRestoreOdData, len(pkgs) == 1); only a list of 2+ names answers per-package lines and END
RESTORE-ODDATA ChooserActivity:installRoamedAppCode 1 # same: one name, one line
RESTORE-ODDATA UnarchiveService:restoreOnlyLocked 1 # same: one name, one line; the list goes through restoreOnlyListLocked (NWP-20261128-16)
RESTORE-ODDATA UnarchiveService:materializeLocked 1 # same: one name, one line
RESTORE-ODDATA UnarchiveService:materializeMember 1 # same: one name, one line'
# Every verb read through a MULTI helper.
export KNOWN_MULTI='FETCH-APP FETCH-ICON GET-APPS GET-BINDINGS GET-CATALOG GET-DOZE-APPS GET-INGEST GET-LOGOFF-REFUSAL
GET-MEDIA-APP-PROGRESS GET-MEDIA-STATUS GET-OTA-TIME GET-OWNER-INBOX GET-PREFS GET-RELOGIN GET-SEAL-BLIND
GET-SNAPSHOTS GET-STORAGE-BREAKDOWN GET-STORAGE-BREAKDOWN-CACHED GET-STORE GET-TELINGEST GET-WIFI-MIRROR GRANT-PERMS LIST-FIDO2
LIST-MEDIA-APPS LIST-UNITS OTA-NOTES OTA-STATUS READ-OWNER-ITEM REPORT-ISSUE RESTORE-ODDATA
SEAL-DELTA SEAL-DELTA-WALK SEARCH-APPS SE-PROGRESS TEL-LIVE-OWNED TEL-OWNED-ICCIDS TEL-OWNED-LABELS'

# The scanner: one awk program over every file. Prints findings and a summary; exits 1 on any finding.
AWK_PROG=$(cat <<'AWK_END'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function loadlist(env, arr, n, i, parts, line, k) {
  n = split(ENVIRON[env], parts, "\n")
  for (i = 1; i <= n; i++) {
    line = parts[i]; sub(/[ \t]*#.*$/, "", line); line = trim(line)
    if (line != "") arr[++arr[0]] = line
  }
}
# code(line): the line with a // comment dropped (string and char literals respected); comment-only lines blank.
function code(s,    t, i, c, n, out, q) {
  t = s; sub(/^[ \t]+/, "", t)
  if (t ~ /^\*/ || t ~ /^\/\*/) return ""
  n = length(s); out = ""; q = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == 1) {
      out = out c
      if (c == "\\") { out = out substr(s, i + 1, 1); i++ }
      else if (c == "\"") q = 0
    } else if (q == 2) {
      out = out c
      if (c == "\\") { out = out substr(s, i + 1, 1); i++ }
      else if (c == "'") q = 0
    } else if (c == "\"") { q = 1; out = out c }
    else if (c == "'") { q = 2; out = out c }
    else if (c == "/" && substr(s, i + 1, 1) == "/") break
    else out = out c
  }
  return out
}
# member(line): the declared name when this is a 4-space-indent member line (method or field), else "".
function member(s,    t, p, q, pos, pre, m) {
  if (s !~ /^    [A-Za-z@]/) return ""
  t = substr(s, 5); sub(/^@[A-Za-z]+ +/, "", t)
  if (t ~ /^(return|new|if|else|for|while|throw|switch|case|try|catch|do)([^A-Za-z0-9_]|$)/) return ""
  p = index(t, "("); q = index(t, " =")
  pos = 0
  if (p > 0) pos = p
  if (q > 0 && (pos == 0 || q < pos)) pos = q
  if (pos == 0) return ""
  pre = substr(t, 1, pos - 1)
  if (match(pre, /[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) { m = substr(pre, RSTART, RLENGTH); sub(/[ \t]+$/, "", m); return m }
  return ""
}
# verbOf(arg): the verb of a literal first argument (text after the opening quote up to \n or the closing quote).
function verbOf(a,    s, i, j) {
  s = substr(a, 2)
  i = index(s, "\\n"); j = index(s, "\"")
  if (i == 0 || (j > 0 && j < i)) i = j
  if (i == 0) return "?"
  return substr(s, 1, i - 1)
}
function addfind(file, ln, verb, helper, rule) {
  printf "%s:%s %s %s rule %s\n", file, ln, verb, helper, rule
  nfind++
}
BEGIN {
  loadlist("ONE_LINE", L1); loadlist("MULTI", LM); loadlist("INLINE", LI)
  loadlist("NONLITERAL", LN); loadlist("ARG_DEPENDENT", LA)
  for (i = 1; i <= L1[0]; i++) { split(L1[i], ar, " "); H[ar[1], ar[2]] = "O"; HF[ar[1] SUBSEP ar[2]] = 1 }
  for (i = 1; i <= LM[0]; i++) { split(LM[i], ar, " "); H[ar[1], ar[2]] = "M" }
  for (i = 1; i <= LI[0]; i++) { split(LI[i], ar, " "); INL[ar[1]] = ar[2] }
  for (i = 1; i <= LN[0]; i++) { split(LN[i], ar, " -> "); NL[ar[1]] = ar[2] }
  for (i = 1; i <= LA[0]; i++) { split(LA[i], ar, " "); AD[ar[1], ar[2]] = ar[3]; ADK[++nad] = ar[1] SUBSEP ar[2] }
  km = ENVIRON["KNOWN_MULTI"]; gsub(/[ \t\n]+/, "\n", km); ENVIRON["KNOWN_MULTI"] = km; loadlist("KNOWN_MULTI", LK)
  for (i = 1; i <= LK[0]; i++) KM[LK[i]] = 1
  nf = 0
}
FNR == 1 { nf++; fname[nf] = FILENAME; sub(/^.*\//, "", fname[nf]); sub(/\.java$/, "", fname[nf]); cnt[nf] = 0 }
{ cnt[nf]++; src[nf, cnt[nf]] = code($0) }
END {
  nfind = 0; nOne = 0; nMulti = 0; ctlBind = 0
  # pass 1: members, calls, connect() lines, string verbs per member
  for (fi = 1; fi <= nf; fi++) {
    F = fname[fi]; cur = ""
    for (n = 1; n <= cnt[fi]; n++) {
      s = src[fi, n]
      m = member(s)
      if (m != "") { cur = m; MEM[F ":" m] = 1 }
      key = F ":" cur
      # string verbs held by the member
      t = s
      while (match(t, /"[A-Z][A-Z0-9-]+(\\n|")/)) {
        v = substr(t, RSTART + 1, RLENGTH - 1); sub(/(\\n|")$/, "", v)
        HOLDS[key SUBSEP v] = 1
        t = substr(t, RSTART + RLENGTH)
      }
      # connect()
      t = s
      if (F == "DaemonSocket") ok = (t ~ /(^|[^A-Za-z0-9_.])connect\(/ && m == "") ; else ok = (t ~ /DaemonSocket\.connect\(/)
      if (ok && cur != "") { CONN[key] = 1; CONNLINE[key] = n }
      if (F == "DaemonSocket") continue
      # helper calls
      t = s
      while (match(t, /[A-Za-z_][A-Za-z0-9_.]*\(/)) {
        tok = substr(t, RSTART, RLENGTH - 1)
        pre = substr(t, 1, RSTART - 1)
        rest = substr(t, RSTART + RLENGTH)
        t = rest
        helperfile = ""; name = tok
        if (tok ~ /^DaemonSocket\./) { name = substr(tok, 14); helperfile = "DaemonSocket" }
        else if (tok ~ /\./) continue
        else helperfile = F
        if (!((name, helperfile) in H)) continue
        # declaration: a type word before the name and the line opens a body / throws
        p2 = pre; sub(/[ \t]+$/, "", p2)
        if (p2 != "" && p2 ~ /[A-Za-z0-9_>\]]$/ && p2 !~ /(^|[^A-Za-z0-9_])(return|new|else|throw|case)$/ && (s ~ /\{[ \t]*$/ || s ~ /throws/)) continue
        # first argument
        a = trim(rest)
        if (a == "") {
          for (k = n + 1; k <= cnt[fi]; k++) { a = trim(src[fi, k]); if (a != "") break }
        }
        kind = H[name, helperfile]
        if (substr(a, 1, 1) == "\"") { lit = 1; verb = verbOf(a) } else { lit = 0; verb = "?" }
        nc++; cF[nc] = F; cL[nc] = n; cM[nc] = cur; cH[nc] = name; cK[nc] = kind; cV[nc] = verb; cLit[nc] = lit
        cHF[nc] = helperfile
        if (kind == "O") { nOne++; if (lit) ONECNT[verb SUBSEP F ":" cur]++ } else nMulti++
        if (kind == "M" && name == "roundTripLines" && verb == "GET-BINDINGS") ctlBind = 1
        if (kind == "M" && lit) SEENVERB[verb] = 1
      }
    }
  }
  # pass 2: rules over the calls
  for (c = 1; c <= nc; c++) {
    F = cF[c]; mem = F ":" cM[c]; v = cV[c]
    if (!cLit[c]) {
      # a helper's own body passes its parameter on
      if ((cM[c], F) in H) continue
      if (mem in NL) { NLUSED[mem] = 1
        if (cK[c] == "O") { nv = split(NL[mem], vs, ","); for (j = 1; j <= nv; j++) if (vs[j] in KM) addfind(F ".java", cL[c], vs[j], cH[c], "i") }
        continue }
      addfind(F ".java", cL[c], "?", cH[c], "iii in " mem); continue
    }
    if (cK[c] == "M") { if (!(v in KM)) addfind(F ".java", cL[c], v, cH[c], "ii"); continue }
    if (v in KM) {
      if ((v, mem) in AD) { if (ONECNT[v SUBSEP mem] == AD[v, mem] + 0) { ADUSED[v SUBSEP mem] = 1; continue } }
      addfind(F ".java", cL[c], v, cH[c], "i in " mem)
    }
  }
  # rule iv: readers
  for (key in CONN) {
    split(key, kp, ":"); F = kp[1]; mname = kp[2]
    if (((mname, F) in H) || (key in INL)) { CONNUSED[key] = 1; continue }
    addfind(F ".java", CONNLINE[key], "-", mname, "iv")
  }
  # rule v: stale pins
  for (i = 1; i <= nad; i++) { split(ADK[i], kp, SUBSEP)
    if (!(ADK[i] in ADUSED) && ONECNT[ADK[i]] == 0) addfind(kp[2], "-", kp[1], "ARG_DEPENDENT", "v") }
  for (key in INL) {
    split(key, kp, ":")
    if (!(key in CONN) || (INL[key] != "-" && !((key SUBSEP INL[key]) in HOLDS))) addfind(kp[1] ".java", "-", INL[key], "INLINE " key, "v")
  }
  for (key in NL) if (!(key in NLUSED)) { split(key, kp, ":"); addfind(kp[1] ".java", "-", NL[key], "NONLITERAL " key, "v") }
  for (hk in H) { split(hk, kp, SUBSEP); if (!((kp[2] ":" kp[1]) in MEM)) addfind(kp[2] ".java", "-", kp[1], "helper", "v") }
  # controls
  if (nOne == 0) { print "CONTROL FAIL: no ONE_LINE call found"; nfind++ }
  if (nMulti == 0) { print "CONTROL FAIL: no MULTI call found"; nfind++ }
  if (!ctlBind) { print "CONTROL FAIL: roundTripLines(\"GET-BINDINGS not seen as a MULTI call"; nfind++ }
  nv = 0; for (v in SEENVERB) nv++
  if (nfind > 0) { printf "FAIL: %d finding(s)\n", nfind; exit 1 }
  printf "PASS: %d one-line calls, %d multi calls, %d multi verbs\n", nOne, nMulti, nv
}
AWK_END
)

# scan <dir>: print findings, return non-zero on any finding or failed control.
scan() {
  local dir=$1 f
  local files=()
  for f in "$dir"/*.java; do files+=("$f"); done
  awk "$AWK_PROG" "${files[@]}"
}

out=$(scan "$SRC"); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit 1
[ "$MUTATE" -eq 1 ] || exit 0

# --mutate: each mutant is applied to a COPY of the sources and must make the scan fail with its own rule.
FAILS=0
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
# convict <Mn> <rule> <dir>: the scan of <dir> must exit non-zero and print a finding for <rule>.
convict() {
  local id=$1 rule=$2 dir=$3 res rc2 o
  o=$(mktemp -p "$W") || { bad "$id: no temp"; return; }
  scan "$dir" > "$o"; rc2=$?
  res=$(grep -E " rule $rule( |\$)" "$o")
  if [ "$rc2" -ne 0 ] && [ -n "$res" ]; then echo "CONVICTED $id (rule $rule)"
  else bad "$id: the scan did not fail with rule $rule (exit $rc2)"; fi
}
# mutant <Mn> <file> <sed-script>: copy the sources, apply sed to <file> in the copy; sets MDIR; fails if unchanged.
mutant() {
  local id=$1 file=$2 script=$3 d
  d=$(mktemp -d -p "$W") || { bad "$id: no temp"; return 1; }
  cp "$SRC"/*.java "$d"/
  sed -e "$script" "$SRC/$file" > "$d/$file"
  if cmp -s "$SRC/$file" "$d/$file"; then bad "$id: mutant changed nothing"; return 1; fi
  MDIR=$d
}
# plant <Mn> <file> <text>: add <text> as a new member before the last line of <file> in a copy.
plant() {
  local id=$1 file=$2 text=$3 d
  d=$(mktemp -d -p "$W") || { bad "$id: no temp"; return 1; }
  cp "$SRC"/*.java "$d"/
  [ "$(tail -n 1 "$d/$file")" = "}" ] || { bad "$id: $file does not end in a closing brace"; return 1; }
  sed '$d' "$SRC/$file" > "$d/$file"
  printf '%s\n}\n' "$text" >> "$d/$file"
  MDIR=$d
}

mutant M1 ChooserActivity.java 's/DaemonSocket\.roundTripLines("GET-BINDINGS\\n"/DaemonSocket.roundTrip("GET-BINDINGS\\n"/' && convict M1 i "$MDIR"
mutant M2 ProfileActivity.java 's/sendDaemonMulti("GET-SNAPSHOTS\\n"/sendDaemon("GET-SNAPSHOTS\\n"/' && convict M2 i "$MDIR"
mutant M3 StoreService.java '/line("GET-ENTITLEMENT\\n", READ_CAP_MS);/a\
            lenReply("NEW-MULTI-VERB\\n", READ_CAP_MS);' && convict M3 ii "$MDIR"
plant M4 GateAlarmActivity.java '    void m4Probe() { String q = "GET-BINDINGS\n"; DaemonSocket.roundTrip(q, 5000); }' && convict M4 iii "$MDIR"
plant M5 GateAlarmActivity.java '    private static String m5Probe() throws Exception {
        android.net.LocalSocket s = DaemonSocket.connect();
        return new java.io.BufferedReader(new java.io.InputStreamReader(s.getInputStream())).readLine();
    }' && convict M5 iv "$MDIR"
mutant M6 ProfileActivity.java 's/sendDaemonMulti("REPORT-ISSUE\\n"/sendDaemon("REPORT-ISSUE\\n"/' && convict M6 i "$MDIR"
mutant M7 ProfileActivity.java '/sendDaemon("REPORT-ISSUE\\n" + reportRequestJson(noteText, false)/d' && convict M7 v "$MDIR"
mutant M8 ChooserActivity.java 's/DaemonSocket\.roundTripLines("GET-MEDIA-STATUS\\n"/DaemonSocket.roundTrip("GET-MEDIA-STATUS\\n"/' && convict M8 i "$MDIR"

if [ "$FAILS" -ne 0 ]; then echo "FAIL: $FAILS mutant check(s) failed"; exit 1; fi
echo "OK: all mutants convicted"
