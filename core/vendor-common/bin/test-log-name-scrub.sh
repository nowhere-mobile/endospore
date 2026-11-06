#!/usr/bin/env bash
# test-log-name-scrub.sh [<nowhere_roamd.sh>] [--mutate] -- every roam.log/mediad.log line that writes the PROFILE
# NAME must land in a shape log_scrub can redact, and log_scrub must redact it whole (NWP-20260922-05,
# NWP-20261008-09).
#
# WHY THIS IS COMMITTED. The logs live on plain /data. They are not inside a user, so the boot-wipe -- which works
# by REMOVING a user -- never touches them; log_scrub's 1 MiB tail is the only rotation (NWP-20261017-01). The only thing that takes a
# departed profile's name out of them is log_scrub, and log_scrub redacts BY SHAPE. So a new log line is a new leak whenever its author
# picks a shape the scrub does not carry, and NOTHING SAYS SO: the line looks right, the scrub reports nothing, and
# the name simply stays on the handset -- where the NEXT profile reads it in "Report an issue" > "View what's sent"
# (report_issue.go collects these logs at session scope, and its `secrets` list holds only the LIVE name).
#
# That is not hypothetical. The scrub was extended three times for exactly this (DIA-20260807-13 found 125
# occurrences of a departed name AFTER the first pass; DIA-20260807-14 added the default-deny quoted-token rule;
# DIA-20260815-12 the ssaid prefix), five fido2 lines joined neither list until 2026-09-22, and NWP-20261008-09
# found the rest: a multi-word name kept every word after the first, a name holding a `"` broke the quoted rule,
# the export line printed the name bare, and the byte cap could cut a name in half before the scrub saw it.
#
# So the invariant is checked STRUCTURALLY, not line by line: run the real emitters with hard planted names (spaces,
# quotes, backslashes, an apostrophe, names holding the very texts the scrub anchors on), plant the lines older builds
# wrote -- raw, and as the previous scrub program already left them, which is what a fielded device holds -- then run
# the real log_scrub FUNCTION (its cap, its self-check, its fallback) twice, and assert every WORD of every planted
# name is GONE BY VALUE, that the second pass changes nothing, and that the diagnostics around the names survive.
# Counting <name> placeholders is what made the DIA-20260807-13 miss look like success.
#
#   bash test-log-name-scrub.sh                         # lint + the emitters + the end-to-end scrub
#   MUTJOBS=8 bash test-log-name-scrub.sh --mutate      # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- no device, no store. The lines, the helper and the scrub are EXTRACTED from nowhere_roamd.sh and
# nowhere_mediad.sh, never copied, so a stale copy here cannot keep passing after the real code moves. The emitters
# run under bash with a `print` shim; on the device they run under mksh, whose echo would undo qn's escaping -- the
# lint below is what holds every qn line to `print -r --`, because bash's echo cannot show that failure.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
MEDIAD="${MEDIAD:-$(dirname "$SUT")/nowhere_mediad.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ -f "$MEDIAD" ] || { echo "no such script: $MEDIAD" >&2; exit 2; }

# The planted names, each hard in its own way: spaces; a quote inside, first (alone, then followed by a word, then
# closed and glued to more), one before a space, four in a row, two around a word; a trailing backslash; an apostrophe;
# a non-ASCII and a punctuation initial (the previous program's remainders start with whatever follows the quote); a
# name that opens with `"<`, which only a quoted placeholder may; and names holding the very texts the rules anchor on
# (` #keys (user`, `ref/export/` and a quote, ` -> ref/export/`, `: sealed 1 bytes -> ref/export/` with and without
# ` (blob`, ` BLANK`, ` ERR-`, ` (1/2)` beside a quote).
PLANTS=('zqplant' 'zqpa zqpb' 'zqq"zqr' '"zqlead' 'zqtrail\' 'zqs\zqt zqu' "zqo'zqbn zqc" 'zqh #keys (user 9'
        'ref/export/zqx"zqy zqz' '"zqlead zqmore' '"zqa"zqb zqc' 'zqa #zqb' 'zqa -> ref/export/zqb'
        'zqs: sealed 1 bytes -> ref/export/zqt' 'zqa BLANKzqc' 'zqa ERR-zqd'
        'Ézqa zqb' '_zqa zqb' 'zqa "zqb" zqc' 'zqa zqb"zqc"zqd' 'zqa" zqb' 'zqa"Ézqb' '"<zq zqw'
        'zqa"zqb"zqc"zqd"zqe' 'zqa zqb" zqc' 'zqa"zqb: sealed 1 bytes -> ref/export/zqc (blob ab)zqd' 'zqa (1/2)zqb\"zqc')
DATE='Mon Oct  8 12:00:00 EDT 2026'

# fragments <name>: every run of the zq marker and the ASCII letters after it -- not the anchor texts planted inside
# the names, which ordinary log lines hold too, and not a character before the marker, so a word that starts with a
# non-ASCII or punctuation character is still found when the scrub leaves it, or its URL escape, behind.
fragments() { printf '%s\n' "$1" | grep -o 'zq[A-Za-z]*'; }
# qs <name>: what qn writes between its quotes -- `\` and `"` backslash-escaped, nothing else. Written out again here
# rather than taken from qn, so a qn that stops escaping cannot pass by agreeing with itself. Go's %q is the same for
# these printable ASCII names, so goq is the daemon's and logProfile's spelling.
qs() { printf '%s\n' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
goq() { printf '"%s"' "$(qs "$1")"; }
# pesc <name>: the key as a request URL carries it (minio-go's EncodePath keeps only A-Za-z0-9 and -_.~/).
pesc() { local s="$1" o="" c i; for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}; case "$c" in [A-Za-z0-9._~/-]) o+="$c" ;; *) o+=$(printf '%%%02X' "'$c") ;; esac; done; printf '%s' "$o"; }

# mksh's builtin, as these scripts use it: print -r -- / print -rn --.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# old_fixtures <name>: every shape an older build wrote the name in -- bare after the verb, bare and then raw-quoted
# fido2, the export key bare (success, retry, URL and cap-flush errors, and minio's closed-connection error, which
# repeats the URL unquoted), a %q name before a second quoted token, and payRent's logProfile under a second %q.
old_fixtures() {
  local pl="$1" q
  q=$(goq "$pl")
  printf '%s\n' \
    "[roamd] OUT $pl (user 11) +de +media $DATE" "[roamd] OUT $pl ERR-NOCREDIT $DATE" \
    "[roamd] OUT $pl #keys sealed (3 pkg, 1 fresh, 0 dropped) $DATE" \
    "[roamd] IN $pl #sys accounts staged (hold) ce=NO de=yes -> user 11 $DATE" \
    "[roamd] IN $pl NEEDKEY (2FA, no key asserted) $DATE" "[roamd] IN $pl BLANK NET $DATE" \
    "[roamd] GRANT $pl #sys accounts placed ce=NO de=yes + reloaded -> user 11 $DATE" \
    "[mediad] start $pl -> user 11 $DATE" \
    "[roamd] fido2-enroll OK for \"$pl\" $DATE" "[roamd] fido2 profile \"$pl\" -> requesting the security key $DATE" \
    "[roamd] fido2-enroll OK for $pl $DATE" "[roamd] fido2 profile $pl -> adopting the NFC pre-asserted hmac $DATE" \
    "push: profile $q p:1a2b #media" "[logind] roam-in $q -> user 12" \
    "[logind] roam-in $q: open \"/data/x y\": permission denied" \
    "[logind] export $q: sealed 2048 bytes -> ref/export/$pl (blob 0123456789ab)" \
    "  retry PUT ref/export/$pl#media (2/5): Put \"https://s3.example/b/ref/export/$(pesc "$pl")%23media\": EOF" \
    "  retry PUT ref/export/$pl (3/5): Put \"https://s3.example/b/ref/export/$(pesc "$pl")\": EOF" \
    "  retry PUT ref/export/$pl#media (4/5): Connection closed by foreign host https://s3.example/b/ref/export/$(pesc "$pl")%23media. Retry again." \
    "[logind] export $q: Put \"https://s3.example/b/ref/export/$(pesc "$pl")\": EOF" \
    "[logind] export $q: Connection closed by foreign host https://s3.example/b/ref/export/$(pesc "$pl"). Retry again." \
    "[logind] export-media $q: Put \"https://s3.example/b/ref/export/$(pesc "$pl")%23media\": EOF" \
    "[logind] export $q: cap-flush: gateway returned no write cap for ref/export/$pl" \
    "[logind] export-media $q: cap-flush: gateway returned no write cap for ref/export/$pl#media" \
    "[logind] export $q: cap-flush: the gateway listed a POINTER as already present (ref/export/$pl) -- only content-addressed blobs are ever skippable; skipping a ref would silently drop this write" \
    "[logind] pay-rent $q: pay-rent: cannot measure $(goq "$q p:1a2b") -- refusing to renew a footprint it cannot see" \
    "[logind] pay-rent $q: pay-rent: cannot measure $(goq "$q") -- refusing to renew a footprint it cannot see"
}

# cur_agent_lines <name>: the daemon's lines as it writes them TODAY (%q, logProfile, redactNameIn, logSafeWhat). Its
# print sites are held by the Go source scan; they are planted here, raw, so the program is held to a fixed point on
# them, and the KEEP lines below to leaving their text whole. payRent's carries the name twice, and a name that holds
# `ref/export/` and a `\"` is split by any rule that ignores escapes and runs before the quoted rule.
cur_agent_lines() {
  local q
  q=$(goq "$1")
  printf '%s\n' \
    "push: profile $q p:1a2b #media" "[logind] roam-in $q -> user 12" \
    "[logind] roam-in $q: open \"/data/x y\": permission denied" \
    "[logind] export $q: sealed 2048 bytes (7-day expiry applied)" \
    "[logind] export $q: Put \"https://s3.example/b/ref/<ref>\": EOF" \
    "[logind] export-media $q: pinned manifest (3 files, 12 bytes, 7-day expiry applied)" \
    "[logind] pay-rent $q: pay-rent: cannot measure $q p:1a2b -- refusing to renew a footprint it cannot see" \
    "[logind] pay-rent $q: paid through epoch 12 (1 token(s) spent)"
}

# What must survive the scrub, and what must not: the text around a name -- on the lines written today, and the
# attempt count and error an OLD retry line kept (`(3/5)`, written only there) -- and the ssaid seed prefix. The agent's
# values that are never a name print with no quote (NWP-20261116-24: logVal's `[PARTIAL 189 2]`, ifaceTok's bare wlan0)
# and must survive whole; a user-named interface stays quoted and must still be redacted.
KEEP=('[restore] skip "net.thunderbird.android/databases/global.db": denied'
  '[roamd] #apps staged 3 pkg(s), 120 KiB, in 40ms (copy 30ms, 0 mtime kept-failed) (NWP-20261005-04, NWP-20261123-02)'
  '[roamd] GRANT checkin kicked for user 11 (android_id bootstrap, installed path)'
  '[roamd] GRANT -> 12 perms + 3 INTERNET default(s) (user 11)'
  '[roamd] GRANT (com.example.app) -> 2 perms + 1 INTERNET default(s) (user 11)'
  '[roamd] OUT "zqkeep" (user 11) +de +media -- PARTIAL: apps=refused'
  '[roamd] OUT "zqkeep" #keys sealed (3 pkg, 1 fresh, 0 dropped)'
  '[roamd] IN "zqkeep" #sys accounts staged (hold) ce=NO de=yes -> user 11'
  '[roamd] GRANT "zqkeep" #sys accounts placed ce=NO de=yes + reloaded -> user 11'
  '[roamd] GRANT "zqkeep" #sys placed a ROW-EMPTY accounts db -- NOT marking .had_account, so this account-less profile can still seal #sys (NWP-20260903-14)'
  '[roamd] seedssaid staged 0123ABCDEF.. user 11 (#210)'
  '[logind] export "zqkeep": sealed 2048 bytes (7-day expiry applied)'
  '[logind] export "zqkeep": Put "https://s3.example/b/ref/<ref>": EOF'
  '[logind] pay-rent "zqkeep": pay-rent: cannot measure "zqkeep" p:1a2b -- refusing to renew a footprint it cannot see'
  '[logind] roam-in "zqkeep": open "/data/x y": permission denied'
  '  retry PUT ref/export/<name> (2/5): Put "https://s3.example/b/ref/export/<name>": EOF'
  '[logind] logout user 30: cutoff [PARTIAL 189 2] in 12620ms, the alarm owner kept -- the apps are stopped before the seal'
  '[logind] locglobals: signout release for user 30 answered [OK] -- the reap and the boot sweep put the baseline back'
  '[resolver] egress iface=wlan0 resolvers=[<net4>:53 1.1.1.1:53] src=discovered dot=off'
  '[resolver] egress iface="wg-home" resolvers=[<net4>:53] src=discovered dot=off')
MUST=('net.thunderbird.android/databases/global.db' '#apps staged 3 pkg(s)' '(copy 30ms, 0 mtime kept-failed)' 'kicked for user 11'
  '12 perms + 3 INTERNET default(s)' '2 perms + 1 INTERNET default(s)' '-- PARTIAL: apps=refused'
  '#keys sealed (3 pkg, 1 fresh, 0 dropped)' 'ce=NO de=yes -> user 11' '+ reloaded -> user 11'
  'placed a ROW-EMPTY accounts db -- NOT marking' 'sealed 2048 bytes (7-day expiry applied)' ': Put "<name>": EOF'
  'p:1a2b -- refusing to renew' ': open "<name>": permission denied' '(2/5): Put "<name>": EOF'
  '(3/5): Put "<name>": EOF'
  'cutoff [PARTIAL 189 2] in 12620ms' 'answered [OK] -- the reap' 'egress iface=wlan0 resolvers=[<net4>:53 1.1.1.1:53]'
  'egress iface="<name>" resolvers=[<net4>:53]')

# --- extraction ---------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
# The top-level definitions log_scrub reads, verbatim and each exactly once.
SCRUB_DEFS="NOWHERE_LOGS LOG_KEEP_BYTES LOG_SCRUB_SED LOG_SCRUB_SED_PREV LOG_SCRUB_PROBE LOG_SCRUB_PROBE_OUT"
defs_of() {
  local v out="" n
  for v in $SCRUB_DEFS; do
    n=$(grep -c "^$v=" "$1")
    [ "$n" = 1 ] || { echo "EXTRACTION FAILED: $v= is defined $n times in $1, want 1" >&2; return 1; }
    out="$out$(grep "^$v=" "$1")"$'\n'
  done
  printf '%s' "$out"
}
# Every line that appends to $LOG and interpolates the profile $name or ${name} (not $names), minus the ones carrying
# an explicit `scrub-exempt:` marker on a preceding comment -- today just reown_restored's local package dir.
name_log_lines() {
  awk '
    /scrub-exempt:/ { exempt = 1; next }   # the marker, then its comment block, then the one line it covers
    /^[ 	]*#/     { next }
    exempt          { exempt = 0; next }
    />> *"\$LOG"/ && /\$(name|\{name\})([^s_a-zA-Z0-9]|$)/ { print }
  ' "$1"
}

# run_scrub <root> <defs> <log_scrub, re-rooted> <program override or empty>: the real function, in a subshell.
run_scrub() {
  ( ROOT="$1"; STATE="$1/state"; LOG="$1/data/nowhere/roam.log"
    eval "$PRINT_SHIM"; eval "$2"
    [ -n "$4" ] && LOG_SCRUB_SED="$4"
    eval "$3"
    log_scrub ) </dev/null >/dev/null 2>&1
}

# suite <roamd> <mediad> [quiet] -> 0 all good, 1 a check failed, 2 the harness could not run (never a verdict).
suite() {
  local f="$1" md="$2" quiet="${3:-}" p=0 x=0 tmp defs scrubfn qn qnm lines ln n pl q lf emit wrote out k miss
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  defs=$(defs_of "$f") || return 2
  scrubfn=$(fn_of "$f" log_scrub)
  qn=$(fn_of "$f" qn); qnm=$(fn_of "$md" qn)
  [ -n "$scrubfn" ] && [ -n "$qn" ] && [ -n "$qnm" ] || { echo "EXTRACTION FAILED: log_scrub or qn not found" >&2; return 2; }
  n=$(grep -c '/data/nowhere/' <<<"$scrubfn")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: log_scrub names /data/nowhere/ $n times, want 1 (re-rooting would be incomplete)" >&2; return 2; }
  scrubfn=${scrubfn//\/data\/nowhere\//\$ROOT\/data\/nowhere\/}

  # The definitions must EVALUATE as extracted: defs_of takes one line per name, so a definition that spans lines
  # leaves its variable unset -- that is the harness failing (rc 2), not the program. An EMPTY value is a real defect
  # and stays a verdict below.
  ( eval "$defs"; for v in $SCRUB_DEFS; do [ -n "${!v+set}" ] || exit 1; done ) >/dev/null 2>&1 \
    || { echo "EXTRACTION FAILED: the extracted definitions of $SCRUB_DEFS do not evaluate (one spans lines?)" >&2; return 2; }
  # A POSITIVE control on the program before anything is concluded from it: an empty or broken program passes
  # every line through, and "the name is not in the output" would then read like a clean scrub.
  local prog prev probe probeout
  prog=$(eval "$defs"; printf '%s' "$LOG_SCRUB_SED"); prev=$(eval "$defs"; printf '%s' "$LOG_SCRUB_SED_PREV")
  probe=$(eval "$defs"; printf '%s' "$LOG_SCRUB_PROBE"); probeout=$(eval "$defs"; printf '%s' "$LOG_SCRUB_PROBE_OUT")
  if [ -n "$prog" ] && [ -n "$prev" ] && [ "$(printf '%s\n' "$probe" | sed -E "$prog" 2>/dev/null)" = "$probeout" ]; then
    ok "the extracted program runs and passes log_scrub's own self-check probe"
  else
    no "the extracted program FAILS the self-check probe -- broken or mis-extracted, so every result below is meaningless"
    return 1
  fi

  # --- lint -----------------------------------------------------------------------------------------------
  [ "$qn" = "$qnm" ] && ok "qn is the same helper in roamd and mediad" || no "qn differs between roamd and mediad"
  lines=$( { name_log_lines "$f"; name_log_lines "$md"; } )
  n=$(grep -c . <<<"$lines")
  [ "$n" -ge 30 ] && ok "collector found $n \$LOG lines carrying the profile name" \
    || no "collector found only $n such lines -- the awk no longer matches, so this suite proves nothing"
  # Every one either hands the name to the agent (which prints it through logProfile, held by the Go source scan)
  # or prints it through qn -- and nothing else bare. A `[ ... ]` test that only READS the name (mediad's argument
  # check) prints nothing, so tests are taken out before looking. A line that went back to the bare name is convicted
  # HERE: the scrub's heal rules would redact it, so the leak checks below cannot see it.
  local bad=""
  while IFS= read -r ln; do
    case "$ln" in *'"$AGENT"'*) continue ;; esac
    if [ "$(sed -e 's/\$(qn "\$name")//g; s/\[ [^]]* \]//g' <<<"$ln" | grep -cE '\$(name|\{name\})([^s_a-zA-Z0-9]|$)')" != 0 ]; then bad="$bad$ln"$'\n'; fi
  done <<<"$lines"
  [ -z "$bad" ] && ok "every log line prints the name through qn (or hands it to the agent)" \
    || { no "lines print the name NOT through qn:"; [ -n "$quiet" ] || printf '%s' "$bad" | sed 's/^/          /'; }
  # ...and writes it with print -r --: this shell's echo turns `\\` back into `\`, undoing the escape, and bash's
  # echo -- which these emitters run under below -- cannot show it.
  bad=$(grep -F '$(qn "$name")' <<<"$lines" | grep -vE 'print -r -- "[^"]*\$\(qn "\$name"\)' || true)
  [ -z "$bad" ] && ok "every qn line writes with print -r --, never echo" \
    || { no "a qn line writes with something other than print -r --:"; [ -n "$quiet" ] || printf '%s\n' "$bad" | sed 's/^/          /'; }

  # --- the emitters ---------------------------------------------------------------------------------------
  # Each line runs alone in its own bash: these are fragments of a larger script, some end in `return 1`, and one
  # that reads stdin would eat the rest of the list (NWP-20260922-05 measured both). Each must write the name as qn's
  # exact token, as qs spells it independently -- so this convicts a qn that stops escaping, or a qn line whose token
  # never reaches the log. (A line that went back to the bare name no longer calls qn and drops out of this loop; the
  # lint above is what convicts it.)
  tmp=$(mktemp -d); : > "$tmp/all.log"
  emit=$(grep -F '$(qn "$name")' <<<"$lines")
  local ne nfail=0
  ne=$(grep -c . <<<"$emit")
  for pl in "${PLANTS[@]}"; do
    q=$(qs "$pl")
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      lf="$tmp/one.log"; : > "$lf"
      # _n and _psn: counts that two emitters test before they write (the #apps Play stack line, NWP-20261021-03).
      env name="$pl" LOG="$lf" uid=11 pass=x RES="$tmp/res" STATE="$tmp/st" AGENT=true _n=1 _psn=1 \
        bash -c "$PRINT_SHIM"$'\n'"$qn"$'\n'"$ln" </dev/null >/dev/null 2>&1
      if ! grep -qF -- "\"$q\"" "$lf"; then
        nfail=$((nfail+1)); [ -n "$quiet" ] || printf '          no qn token for %s from: %s\n' "$pl" "$ln"
      fi
      cat "$lf" >> "$tmp/all.log"
    done <<<"$emit"
  done
  [ "$ne" -ge 30 ] && [ "$nfail" = 0 ] && ok "all $ne qn emitters wrote each planted name as one escaped quoted token" \
    || no "$nfail emitter run(s) did not write the qn token ($ne emitters)"

  # --- what older builds left: the raw lines, and the same lines after the PREVIOUS program scrubbed them; then the
  # --- daemon's lines as it writes them today ----------------------------------------------------------------------
  for pl in "${PLANTS[@]}"; do old_fixtures "$pl"; done > "$tmp/old.log"
  cat "$tmp/old.log" >> "$tmp/all.log"
  sed -E "$prev" "$tmp/old.log" >> "$tmp/all.log"
  for pl in "${PLANTS[@]}"; do cur_agent_lines "$pl"; done >> "$tmp/all.log"
  printf '%s\n' "${KEEP[@]}" >> "$tmp/all.log"

  # --- the REAL log_scrub, over two of its five logs, then again over its own output ------------------------
  local R="$tmp/root"; mkdir -p "$R/data/nowhere" "$R/state"
  cp "$tmp/all.log" "$R/data/nowhere/roam.log"; cp "$tmp/all.log" "$R/data/nowhere/login.log"
  run_scrub "$R" "$defs" "$scrubfn" ""
  for lf in roam login; do
    out=$(cat "$R/data/nowhere/$lf.log")
    wrote=""
    for pl in "${PLANTS[@]}"; do
      while IFS= read -r q; do
        [ -n "$q" ] || continue
        if grep -qF -- "$q" <<<"$out"; then wrote="$wrote $q"; fi
      done < <(fragments "$pl")
    done
    [ -z "$wrote" ] && ok "$lf.log: no word of any planted name survives log_scrub" \
      || { no "$lf.log: these survive log_scrub:$wrote"; [ -n "$quiet" ] || grep -F -- "$(tr ' ' '\n' <<<"${wrote# }")" <<<"$out" | head -5 | sed 's/^/          /'; }
  done
  out=$(cat "$R/data/nowhere/roam.log")
  grep -qF 0123ABCDEF <<<"$out" && no "the ssaid seed prefix survives log_scrub" || ok "the ssaid seed prefix is redacted"
  grep -q 'log_scrub:.*self-check' <<<"$out" && no "log_scrub says its program FAILED the self-check on this sed" \
    || ok "log_scrub's self-check passed (no fallback)"
  # Every reap and boot re-scrubs the kept tail, so the program must be a FIXED POINT: a second pass that changes a
  # line means the line loses something at every scrub (a once-scrubbed name meeting a heal rule again).
  cp "$R/data/nowhere/roam.log" "$tmp/first.log"
  run_scrub "$R" "$defs" "$scrubfn" ""
  cmp -s "$tmp/first.log" "$R/data/nowhere/roam.log" && ok "a second scrub changes nothing (a fixed point)" \
    || { no "a second scrub changes the log -- every reap and boot would keep eating it:"; [ -n "$quiet" ] || diff "$tmp/first.log" "$R/data/nowhere/roam.log" | head -6 | sed 's/^/          /'; }
  out=$(cat "$R/data/nowhere/roam.log")
  miss=""
  for k in "${MUST[@]}"; do grep -qF -- "$k" <<<"$out" || miss="$miss [$k]"; done
  [ -z "$miss" ] && ok "after two scrubs, [restore] paths and the text around a name survive" \
    || no "the scrub ate diagnostics it must keep:$miss"

  # --- the cap: a name the byte cut lands inside must not survive (LOG (4)) ---------------------------------
  # The cut is placed inside the FIRST word of an old two-word name, so cutting before the scrub leaves the
  # second word whole with no anchor left to find it -- which is what the old order did.
  local R2="$tmp/root2" cut tailbytes keep
  mkdir -p "$R2/data/nowhere" "$R2/state"
  cut='qpa zqpb (user 11)'
  keep=$(eval "$defs"; printf '%s' "$LOG_KEEP_BYTES")
  tailbytes=$(( keep - ${#cut} - 1 ))
  { printf '%s\n' "[roamd] filler before" "[roamd] OUT zqpa zqpb (user 11)"; head -c $((tailbytes - 1)) /dev/zero | tr '\0' x; printf '\n'; } \
    > "$R2/data/nowhere/roam.log"
  run_scrub "$R2" "$defs" "$scrubfn" ""
  if grep -q zqpb "$R2/data/nowhere/roam.log"; then no "a name the byte cap cut in half survives (the cap ran before the scrub)"
  elif [ "$(wc -c < "$R2/data/nowhere/roam.log")" -gt "$keep" ]; then no "the log was not capped"
  else ok "the cap runs after the scrub: no fragment of a name cut by it survives, and the log is capped"; fi

  # --- the self-check's fallback: a program this sed cannot compile must not leave the logs unscrubbed ------
  local R3="$tmp/root3"
  mkdir -p "$R3/data/nowhere" "$R3/state"
  printf '%s\n' '[roamd] OUT zqplant (user 11)' > "$R3/data/nowhere/roam.log"
  run_scrub "$R3" "$defs" "$scrubfn" 's/(/x/'
  out=$(cat "$R3/data/nowhere/roam.log")
  if grep -q zqplant <<<"$out"; then no "with a broken program the logs stay UNSCRUBBED -- the fallback did not run"
  elif ! grep -q 'log_scrub:.*self-check' <<<"$out"; then no "with a broken program the fallback ran silently -- it must say so in roam.log"
  else ok "a broken program fails the self-check, says so, and the previous program still scrubs"; fi

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  rm -rf "$tmp"
  [ "$x" -eq 0 ]
}

echo "log-name scrub: $SUT + $MEDIAD"
suite "$SUT" "$MEDIAD"; rc=$?
[ "$rc" = 0 ] || { [ "$rc" = 2 ] && echo "HARNESS ERROR (rc=2): not a verdict"; FAILED=1; }

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT; a PROBE must stay green):"
  MUTJOBS=${MUTJOBS:-1}
  mtmp=$(mktemp -d); MN=0
  # mutate <label> <roamd|mediad> <literal needle> <replacement> [survive]. Literal, not a regex: the needles are
  # shell and sed programs, and escaping them for sed is exactly the kind of error that turns a mutant into a no-op.
  # With MUTJOBS > 1 the verdicts run in parallel; each writes its own result file, printed in order at the end.
  mutate() {
    local label="$1" which="$2" needle="$3" repl="$4" want="${5:-convict}" src m d
    MN=$((MN + 1)); d="$mtmp/m$MN"; mkdir -p "$d"
    case "$which" in roamd) src="$SUT" ;; mediad) src="$MEDIAD" ;; esac
    m=$(cat "$src"; printf x); m=${m%x}
    if [ "${m/"$needle"/}" = "$m" ]; then printf '  SKIP  %-64s needle not found -- a NO-OP\n' "$label" > "$d/res"; return; fi
    if [ "${m/"$needle"/}" != "${m//"$needle"/}" ]; then printf '  ERR   %-64s needle is not unique\n' "$label" > "$d/res"; return; fi
    cp "$SUT" "$d/nowhere_roamd.sh"; cp "$MEDIAD" "$d/nowhere_mediad.sh"
    # The replacement is QUOTED: since bash 5.2 an unquoted one expands `&` to the match (patsub_replacement).
    printf '%s' "${m/"$needle"/"$repl"}" > "$d/nowhere_$which.sh"
    if ! bash -n "$d/nowhere_roamd.sh" 2>/dev/null || ! bash -n "$d/nowhere_mediad.sh" 2>/dev/null; then
      printf '  ERR   %-64s mutant does not parse\n' "$label" > "$d/res"; return
    fi
    judge() {
      local r
      suite "$d/nowhere_roamd.sh" "$d/nowhere_mediad.sh" quiet >/dev/null 2>&1; r=$?
      case "$want:$r" in
        convict:1) printf '  ok    %-64s convicted\n' "$label" ;;
        survive:0) printf '  ok    %-64s stayed green (PROBE)\n' "$label" ;;
        convict:0) printf '  XX    %-64s SURVIVED\n' "$label" ;;
        survive:1) printf '  XX    %-64s PROBE went red: the suite pins prose\n' "$label" ;;
        *)         printf '  ERR   %-64s harness error (rc=%s), not a verdict\n' "$label" "$r" ;;
      esac > "$d/res"
    }
    if [ "$MUTJOBS" -gt 1 ]; then
      while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do sleep 0.2; done
      judge &
    else
      judge
    fi
  }
  # the emitters
  mutate 'an OUT line prints the name bare again' roamd \
    'print -r -- "[roamd] OUT $(qn "$name") (user $uid) +de +media $(date)" >> "$LOG"' \
    'print -r -- "[roamd] OUT $name (user $uid) +de +media $(date)" >> "$LOG"'
  mutate 'a fido2 line writes the name raw in quotes again' roamd \
    'fido2-enroll OK for $(qn "$name")' 'fido2-enroll OK for \"$name\"'
  mutate 'mediad prints the name bare again' mediad \
    'print -r -- "[mediad] start $(qn "$name") -> user' 'print -r -- "[mediad] start $name -> user'
  mutate 'a qn line is written with echo' roamd \
    'print -r -- "[roamd] IN $(qn "$name") NEEDKEY' 'echo "[roamd] IN $(qn "$name") NEEDKEY'
  mutate 'qn stops escaping a quote' roamd "; s/\"/\\\\\"/g')\\\"\"" "')\\\"\""
  # the program, rule by rule, from the rule texts themselves (each must occur exactly once, or mutate says so):
  # every rule is load-bearing, so each removal must convict, and so must each narrowing below
  R1EXPORT='s/^(\[logind\] export(-media)? ).*(: sealed [0-9]+ bytes -> ref\/export\/).*( \(blob [0-9a-f]+\))$/\1"<name>"\3<name>\4/'
  R1RETRY='s/^( *retry [A-Za-z ]*ref\/export\/).*( \([0-9]+\/[0-9]+\): )/\1<name>\2/'
  R1SPLIT='s/^( *retry [A-Za-z ]*ref\/export\/)([^<]|<[^n]|<n[^a]|<na[^m]|<nam[^e]|<name[^>]|<name>[^ ]|<name> [^(]).*/\1<name>/'
  R1NOCAP='s/^(\[logind\] export(-media)? ).*(: cap-flush: gateway returned no write cap for ref\/export\/).*/\1"<name>"\3<name>/'
  R1POINTER='s/^(\[logind\] export(-media)? ).*(: cap-flush: the gateway listed a POINTER as already present \(ref\/export\/).*(\) -- only content-)/\1"<name>"\3<name>\4/'
  R1FIDO='s/^(\[roamd\] fido2 profile ).*( -> (adopting|NFC-first|requesting))/\1"<name>"\2/'
  R1ENROLL='s/^(\[roamd\] fido2-enroll (OK|FAILED) for ).*( (Mon|Tue|Wed|Thu|Fri|Sat|Sun) )/\1"<name>"\3/'
  R2='/^\[restore\]/! s/"([^"\\]|\\.)*"/"<name>"/g'
  R2SPLIT='s/^(\[logind\] (export(-media)?|pay-rent) )"<name>"([^:]|:[^ ]).*/\1"<name>"/'
  R3CHAIN='/^\[restore\]/! s/"<name>"([^"]*\\"<name>")+/"<name>"/g'
  R3ODD='/^\[restore\]/! s/^([^"]*)"<name>"([^"]*"[^"]*")*[^"]*"([^"]*)$/\1"<name>"\3/'
  R4IN='s/(\[roamd\] IN )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| NEEDKEY| -> user| BLANK)/\1<name>\3/'
  R4GRANT='s/(\[roamd\] GRANT )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #)/\1<name>\3/'
  R4OUT='s/(\[roamd\] OUT )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| \(user| ERR-)/\1<name>\3/'
  R4MEDIAD='s/(\[mediad\] start )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).* -> user/\1<name> -> user/'
  R5='/^\[restore\]/! s/(ref(\/|%2[Ff])export(\/|%2[Ff]))[^ "&?]+/\1<name>/g'
  mutate 'rule 1: the export-line heal is gone' roamd "$R1EXPORT; " ''
  mutate 'rule 1: the export-line heal loses its end anchor' roamd '( \(blob [0-9a-f]+\))$/' '( \(blob [0-9a-f]+\))/'
  mutate 'rule 1: the retry heal is gone' roamd "$R1RETRY; " ''
  mutate 'rule 1: the retry heal loses the colon after its count' roamd '( \([0-9]+\/[0-9]+\): )/' '( \([0-9]+\/[0-9]+\))/'
  mutate 'rule 1: the split-retry heal is gone' roamd "$R1SPLIT; " ''
  mutate 'rule 1: the no-write-cap heal is gone' roamd "$R1NOCAP; " ''
  mutate 'rule 1: the POINTER heal is gone' roamd "$R1POINTER; " ''
  mutate 'rule 1: the fido2 profile heal is gone' roamd "$R1FIDO; " ''
  mutate 'rule 1: the fido2-enroll heal is gone' roamd "$R1ENROLL; " ''
  mutate 'rule 2: the escape-aware quoted rule is gone' roamd "$R2; " ''
  mutate 'rule 2: it eats [restore] paths' roamd '/^\[restore\]/! s/"([^"\\]|\\.)*"' 's/"([^"\\]|\\.)*"'
  mutate 'rule 2: the split export/pay-rent heal is gone' roamd "$R2SPLIT; " ''
  mutate 'rule 2: that heal cuts the lines written today too' roamd '"<name>"([^:]|:[^ ]).*/' '"<name>".*/'
  mutate 'rule 3: the backslash-remainder chain is gone' roamd "$R3CHAIN; " ''
  mutate 'rule 3: it takes one remainder, not a chain' roamd '"<name>"([^"]*\\"<name>")+/' '"<name>"[^"]*\\"<name>"/'
  mutate 'rule 3: the odd-quote heal is gone' roamd "$R3ODD; " ''
  mutate 'rule 4: the IN heal is gone' roamd "$R4IN; " ''
  mutate 'rule 4: the GRANT heal is gone' roamd "$R4GRANT; " ''
  mutate 'rule 4: the OUT heal is gone' roamd "$R4OUT; " ''
  mutate 'rule 4: the mediad heal is gone' roamd "$R4MEDIAD; " ''
  mutate 'rule 4: the GRANT heal reaches " (user" again' roamd '( #)/\1<name>\3/; ' '( #| \(user)/\1<name>\3/; '
  mutate 'rule 4: a name opening with "< passes for a placeholder again' roamd \
    's/(\[roamd\] IN )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ])' 's/(\[roamd\] IN )([^"]|"[^<]|"<name>"[^ ])'
  mutate 'the previous one-word rule is back' roamd "$R4MEDIAD; " \
    "$R4MEDIAD; "'s/(\[roamd\] (IN|OUT|GRANT) )[^ ]+/\1<name>/g; '
  mutate 'rule 5: the URL-key rule is gone' roamd "$R5; " ''
  # MOVED, not copied: a copy ahead of rule 2 would leave the later one to repair what it broke.
  mutate 'rule 5 runs before rule 2' roamd \
    "$R2; $R2SPLIT; $R3CHAIN; $R3ODD; $R4IN; $R4GRANT; $R4OUT; $R4MEDIAD; $R5; " \
    "$R5; $R2; $R2SPLIT; $R3CHAIN; $R3ODD; $R4IN; $R4GRANT; $R4OUT; $R4MEDIAD; "
  # (rule 4 run before rule 3 is not here: only a name that opens with a quote shows it, and such a name is an
  # accepted bound on the old bare lines, so no plant can carry it; log_scrub_fuzz_test.go's fixed point pins it.)
  mutate 'rule 6: the ssaid rule is gone' roamd "; s/(seedssaid staged )[0-9A-Fa-f]+\\.\\./\\1<redacted>../g'" "'"
  # log_scrub itself
  mutate 'the scrub cuts before it redacts again' roamd \
    'sed -E "$_p" "$_f" 2>/dev/null > "$STATE/.logscrub"' \
    'tail -c "$LOG_KEEP_BYTES" "$_f" 2>/dev/null | sed -E "$_p" > "$STATE/.logscrub" 2>/dev/null'
  mutate 'log_scrub always runs the previous program' roamd '  _p=$LOG_SCRUB_SED'$'\n' '  _p=$LOG_SCRUB_SED_PREV'$'\n'
  mutate 'the self-check never falls back' roamd '    _p=$LOG_SCRUB_SED_PREV' '    :'
  mutate 'PROBE: the self-check message is reworded' roamd \
    'the scrub program FAILED its self-check' 'the scrub program did not pass its self-check' survive
  wait
  # A mutant whose judge died leaves an empty or missing result: that is no verdict, never a pass. So both counts must
  # hold -- exactly MN ok lines, and nothing else.
  for ((i = 1; i <= MN; i++)); do
    if [ -s "$mtmp/m$i/res" ]; then cat "$mtmp/m$i/res"; else printf '  ERR   mutant %d left no verdict\n' "$i"; fi
  done > "$mtmp/all"
  cat "$mtmp/all"
  echo
  nok=$(grep -c '^  ok ' "$mtmp/all")
  if [ "$nok" = "$MN" ] && [ "$(grep -c -v '^  ok ' "$mtmp/all")" = 0 ]; then echo "ALL $MN MUTATIONS BEHAVED"
  else echo "PROBLEM: a mutation did not behave ($nok of $MN verdicts ok)"; FAILED=1; fi
  rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
