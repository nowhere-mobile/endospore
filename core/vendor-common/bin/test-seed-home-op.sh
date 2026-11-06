#!/usr/bin/env bash
# test-seed-home-op.sh [<nowhere_roamd.sh>] [--mutate] -- what the `seed-home` op's two helpers do as root against a
# fresh profile's app data that test-seed-home-verdict.sh (NWP-20261015-39) does not pin (NWP-20261015-34).
#
# WHY THIS IS COMMITTED.
#   - seed_home captures the tool's stdout for its `seeded*` decision and sends stderr to $LOG. Capturing both with
#     2>&1 put the "malformed line(s) skipped" note first, the prefix match failed and the launcher was never
#     restarted (the function's own comment: "Found by actually running the tool"). Nothing pinned the split.
#   - seed_aurora_installer writes into Aurora's CE dir and chowns to a uid it reads with `stat`. Its rules -- skip
#     when Aurora is absent, never clobber an existing prefs file (it holds the anonymous-session AUTH_DATA), refuse a
#     non-numeric owner (`chown :` or a root-owned prefs file Aurora cannot read) -- are all silent when broken.
# seed_home's per-branch verdicts, the 25 s poll and the op arm belong to test-seed-home-verdict.sh and are not repeated.
#
# Both functions are extracted from nowhere_roamd.sh BY NAME, never copied. Their three hardcoded paths are rewritten to
# a temp root (the exact changed-line count is required). am, chown, chmod, chcon, restorecon and sleep record argv (chcon
# fails when a case sets CHCON=FAIL); stat answers the owner uid a case sets for `stat -c %u <aurora dir>` and the SELinux
# context a case sets for `stat -c %C <aurora dir>` (default app_data_file with categories), and fails for any other
# argument shape; the tool is a script whose stdout, stderr and rc a case sets. Every case runs under bash, sh, dash and
# mksh (those present).
#
# seed_aurora_installer labels what it creates by copying the package dir's own context with `chcon -h`, as
# relabel_restored does (NWP-20261109-13): toybox `restorecon -R` without -D relabels nothing under an app dir, so the
# prefs file that later holds Aurora's AUTH_DATA kept roamd's bare s0. The cases pin which entries are chcon'd, with
# which context, and that an unexpected dir context seeds nothing.
#
#   bash test-seed-home-op.sh            # the cases
#   bash test-seed-home-op.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  skip  shell $s not installed"; fi
done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

EXPECT_XML="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name=\"PREFERENCE_INSTALLER_ID\" value=\"3\" />
</map>"

# extract <roamd.sh> <out> -> the two functions with their three hardcoded paths rewritten to $R/...; 1 = extraction failed
extract() {  # the paths become "$R/..." -- R is the case root, set by the driver
  local f="$1" out="$2" body changed
  body=$(sed -n '/^seed_home() {$/,/^}$/p; /^seed_aurora_installer() {$/,/^}$/p' "$f")
  case "$body" in *'seed_home() {'*) ;; *) return 1 ;; esac
  case "$body" in *'seed_aurora_installer() {'*) ;; *) return 1 ;; esac
  printf '%s\n' "$body" | sed \
    -e "s@\"/system/etc/nowhere/default-home\"@\"\$R/desc\"@" \
    -e "s@\"/system/bin/nowhere_seed_home\"@\"\$R/tool\"@" \
    -e "s@\"/data/user/\$uid/com.aurora.store\"@\"\$R/data/\$uid/com.aurora.store\"@" > "$out"
  changed=$(diff <(printf '%s\n' "$body") "$out" | grep -c '^>')
  [ "$changed" = 3 ] || return 1
}

# the stubs, sourced ahead of the functions
STUBS=$(cat <<'EOS'
am()        { echo "am $*" >> "$R/calls"; }
chown()     { echo "chown $*" >> "$R/calls"; }
chmod()     { echo "chmod $*" >> "$R/calls"; }
chcon()     { echo "chcon $*" >> "$R/calls"; [ "${CHCON:-}" != FAIL ]; }
restorecon(){ echo "restorecon $*" >> "$R/calls"; }
sleep()     { echo "sleep $*" >> "$R/calls"; }
stat()      {
  [ "$#" = 3 ] && [ "$1" = -c ] && [ "$3" = "$R/data/$UID_/com.aurora.store" ] || return 1
  case "$2" in
    %u) [ "${OWNER:-}" = FAIL ] && return 1; echo "$OWNER" ;;
    %C) [ "${CTX:-}" = FAIL ] && return 1; echo "${CTX:-u:object_r:app_data_file:s0:c522,c768}" ;;
    *) return 1 ;;
  esac
}
EOS
)

# run_case <functions-file> <shell> <root> <driver-body> -> runs with R/LOG/UID_ set
run_case() {
  local fns="$1" sh="$2" R="$3" body="$4"
  {
    echo "R='$R'; LOG='$R/log'; UID_=10; uid=10"
    printf '%s\n' "$STUBS"
    cat "$fns"
    printf '%s\n' "$body"
  } > "$R/run.sh"
  "$sh" "$R/run.sh" > "$R/stdout" 2>"$R/stderr"
}

mk_root() {
  local R; R=$(mktemp -d -p "$W")
  mkdir -p "$R/user/com.android.launcher3/databases"
  : > "$R/user/com.android.launcher3/databases/launcher.db"
  : > "$R/calls"; : > "$R/log"
  echo x > "$R/desc"
  echo "$R"
}

# mk_tool <root> <stdout> <stderr> <rc>
mk_tool() {
  printf '%s' "$2" > "$1/tool.out"; printf '%s' "$3" > "$1/tool.err"
  printf '#!/bin/sh\n[ -s "%s/tool.out" ] && cat "%s/tool.out"\n[ -s "%s/tool.err" ] && cat "%s/tool.err" >&2\nexit %s\n' \
    "$1" "$1" "$1" "$1" "$4" > "$1/tool"
  chmod +x "$1/tool"
}

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 sh R fns n calls stops adir xml log o D X C P
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  fns=$(mktemp -p "$W"); R=$(mktemp -d -p "$W")
  if ! extract "$f" "$fns"; then
    echo "EXTRACTION FAILED: seed_home / seed_aurora_installer or their three paths in $f" >&2
    rm -rf "$fns" "$R"; return 2
  fi
  for sh in $SHELLS; do
    "$sh" -n "$fns" 2>/dev/null || { echo "EXTRACTION FAILED: extracted code does not parse under $sh" >&2; rm -rf "$fns" "$R"; return 2; }
  done
  rm -rf "$R"
  export CTX= CHCON=
  D='<R>/data/10/com.aurora.store/shared_prefs'; X="$D/com.aurora.store_preferences.xml"
  C='u:object_r:app_data_file:s0:c522,c768'; P='u:object_r:privapp_data_file:s0:c512,c768'

  for sh in $SHELLS; do
    # --- seed_home: the stdout/stderr split ---
    R=$(mk_root); mk_tool "$R" "seeded 2" "seed-home: 2 malformed line(s) skipped" 0
    run_case "$fns" "$sh" "$R" 'OUT=; seed_home 10 "$R/user"; echo "$SEED_VERDICT" > "$R/verdict"'
    stops=$(grep -c '^am force-stop --user 10 com.android.launcher3$' "$R/calls")
    [ "$stops" = 1 ] && [ "$(grep -c . "$R/calls")" = 1 ] && ok "[$sh] stderr note + seeded 2 -> exactly one force-stop" || no "[$sh] stderr note + seeded 2: calls=$(tr '\n' ';' < "$R/calls")"
    [ "$(cat "$R/verdict")" = "OK SEEDED 2" ] && ok "[$sh] the stderr note does not reach the decision (verdict OK SEEDED 2)" || no "[$sh] verdict '$(cat "$R/verdict")'"
    log=$(cat "$R/log")
    case "$log" in *$'\n'"seed-home: 2 malformed line(s) skipped"*|"seed-home: 2 malformed line(s) skipped"*) ok "[$sh] the stderr note lands in \$LOG" ;; *) no "[$sh] note missing from LOG: $log" ;; esac
    case "$log" in *"[roamd] seed-home: seeded 2 (user 10)"*) ok "[$sh] the logged tool output is the stdout alone" ;; *) no "[$sh] stdout log line: $log" ;; esac
    case "$log" in *"seed-home: seeded 2 malformed"*|*"[roamd] seed-home: seed-home:"*) no "[$sh] stderr leaked into the captured stdout" ;; *) ok "[$sh] stderr is not in the captured stdout" ;; esac
    [ ! -s "$R/stderr" ] && ok "[$sh] the note did not go to the caller's stderr" || no "[$sh] caller stderr: $(cat "$R/stderr")"
    rm -rf "$R"

    R=$(mk_root); mk_tool "$R" "seeded 3" "" 0
    run_case "$fns" "$sh" "$R" 'seed_home 10 "$R/user"'
    stops=$(grep -c '^am force-stop --user 10 com.android.launcher3$' "$R/calls")
    [ "$stops" = 1 ] && ok "[$sh] control: seeded 3 alone -> one force-stop" || no "[$sh] control: stops=$stops"
    rm -rf "$R"

    # --- seed_aurora_installer ---
    R=$(mk_root); OWNER=10123 export OWNER
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    [ ! -e "$R/data" ] && [ ! -s "$R/calls" ] && [ ! -s "$R/log" ] && ok "[$sh] no Aurora dir -> nothing written, nothing called" || no "[$sh] absent Aurora wrote: $(find "$R/data" 2>/dev/null) $(cat "$R/calls")"
    rm -rf "$R"

    R=$(mk_root); adir="$R/data/10/com.aurora.store"; xml="$adir/shared_prefs/com.aurora.store_preferences.xml"
    mkdir -p "$adir/shared_prefs"; printf '<map><string name="AUTH_DATA">keep</string></map>\n' > "$xml"; cp "$xml" "$R/before"
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    cmp -s "$xml" "$R/before" && ok "[$sh] an existing prefs file is untouched byte for byte" || no "[$sh] existing prefs file was changed"
    [ ! -s "$R/calls" ] && [ ! -s "$R/log" ] && ok "[$sh] A4 an existing prefs file -> no chown/chmod/chcon, no log" || no "[$sh] A4 existing prefs: $(cat "$R/calls")"
    rm -rf "$R"

    # A1: a fresh dir -- the file and the shared_prefs dir this call created take the package dir's own context
    R=$(mk_root); adir="$R/data/10/com.aurora.store"; xml="$adir/shared_prefs/com.aurora.store_preferences.xml"
    mkdir -p "$adir"
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    [ "$(cat "$xml" 2>/dev/null)" = "$EXPECT_XML" ] && ok "[$sh] owner 10123 -> prefs xml with PREFERENCE_INSTALLER_ID 3" || no "[$sh] xml: $(cat "$xml" 2>/dev/null)"
    calls=$(sed "s@$R@<R>@g" "$R/calls")
    [ "$calls" = "chown 10123:10123 $D $X
chmod 0771 $D
chmod 0660 $X
chcon -h $C $X
chcon -h $C $D" ] && ok "[$sh] A1 chown 10123:10123 on dir and file, modes 0771/0660, the dir's context chcon'd onto file and created dir" || no "[$sh] A1 calls: $calls"
    case "$calls" in *restorecon*) no "[$sh] A1 restorecon called: $calls" ;; *) ok "[$sh] A1 no restorecon (it relabels nothing under an app dir)" ;; esac
    log=$(cat "$R/log")
    case "$log" in *"seeded Aurora installer=Services (user 10)"*) ok "[$sh] the seeding is logged" ;; *) no "[$sh] no seeded log line" ;; esac
    case "$log" in *WARN*) no "[$sh] A1 WARN logged: $log" ;; *) ok "[$sh] A1 no WARN" ;; esac
    rm -rf "$R"

    # A1 privapp: the accepted privapp_data_file shape, and the chcon carries exactly what stat answered
    R=$(mk_root); mkdir -p "$R/data/10/com.aurora.store"; CTX=$P
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    calls=$(sed "s@$R@<R>@g" "$R/calls"); CTX=
    case "$calls" in *"chcon -h $P $X"*"chcon -h $P $D") ok "[$sh] A1 a privapp_data_file dir context is copied as is" ;; *) no "[$sh] A1 privapp calls: $calls" ;; esac
    rm -rf "$R"

    # A2: shared_prefs already there (Aurora's own) -- only the file is chcon'd, never the pre-existing dir
    R=$(mk_root); adir="$R/data/10/com.aurora.store"; xml="$adir/shared_prefs/com.aurora.store_preferences.xml"
    mkdir -p "$adir/shared_prefs"
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    [ "$(cat "$xml" 2>/dev/null)" = "$EXPECT_XML" ] && ok "[$sh] A2 existing shared_prefs -> prefs xml written" || no "[$sh] A2 xml: $(cat "$xml" 2>/dev/null)"
    calls=$(sed "s@$R@<R>@g" "$R/calls")
    [ "$calls" = "chown 10123:10123 $D $X
chmod 0771 $D
chmod 0660 $X
chcon -h $C $X" ] && ok "[$sh] A2 only the file is chcon'd" || no "[$sh] A2 calls: $calls"
    case "$calls" in *"chcon -h $C $D"|*"chcon -h $C $D"$'\n'*) no "[$sh] A2 the pre-existing dir was chcon'd" ;; *) ok "[$sh] A2 the pre-existing shared_prefs keeps its own label" ;; esac
    rm -rf "$R"

    # A3: an unexpected dir context (or none) -> nothing created, nothing called, one WARN
    for o in u:object_r:system_data_file:s0 FAIL; do
      R=$(mk_root); mkdir -p "$R/data/10/com.aurora.store"; CTX=$o
      run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
      CTX=; n=$o; [ "$o" = FAIL ] && n=none
      [ ! -e "$R/data/10/com.aurora.store/shared_prefs" ] && [ ! -s "$R/calls" ] && ok "[$sh] A3 context '$o' -> nothing created, no chown/chmod/chcon" || no "[$sh] A3 context '$o' wrote: $(find "$R/data" | tr '\n' ' ') $(cat "$R/calls")"
      log=$(cat "$R/log")
      [ "$log" = "[roamd] WARN seed-aurora: unexpected dir context [$n] -- nothing seeded (NWP-20261109-13)" ] && ok "[$sh] A3 context '$o' -> the WARN line alone" || no "[$sh] A3 context '$o' log: $log"
      rm -rf "$R"
    done

    # A5: a failing chcon -> one WARN per entry, by basename only; the seeding is still logged
    R=$(mk_root); mkdir -p "$R/data/10/com.aurora.store"; CHCON=FAIL
    run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
    CHCON=; log=$(cat "$R/log")
    [ "$log" = "[roamd] WARN seed-aurora: chcon com.aurora.store_preferences.xml failed (NWP-20261109-13)
[roamd] WARN seed-aurora: chcon shared_prefs failed (NWP-20261109-13)
[roamd] seeded Aurora installer=Services (user 10)" ] && ok "[$sh] A5 failing chcon -> a WARN naming each entry by basename, then the seeded line" || no "[$sh] A5 log: $log"
    case "$log" in *"$R"*|*/data/*) no "[$sh] A5 the log carries a path" ;; *) ok "[$sh] A5 no path in the log" ;; esac
    rm -rf "$R"

    for o in abc FAIL; do
      R=$(mk_root); mkdir -p "$R/data/10/com.aurora.store"; OWNER=$o export OWNER
      run_case "$fns" "$sh" "$R" 'seed_aurora_installer 10'
      [ ! -e "$R/data/10/com.aurora.store/shared_prefs" ] && [ ! -s "$R/calls" ] && ok "[$sh] owner '$o' -> nothing written" || no "[$sh] owner '$o' wrote: $(find "$R/data" | tr '\n' ' ') $(cat "$R/calls")"
      rm -rf "$R"
    done
    export OWNER=10123
  done

  rm -f "$fns"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "seed-home op helpers: $SUT (shells:$SHELLS)"
suite "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d -p "$W")
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r res t bad=""
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-62s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-62s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    # not quiet: a conviction needs a FAIL line under every shell's own tag, mksh's included
    res=$(suite "$mf" 2>&1); r=$?
    for t in $SHELLS; do
      case "$res" in *"  FAIL  [$t]"*) ;; *) bad="$bad $t" ;; esac
    done
    case "$r" in
      0) printf '  XX    %-62s SURVIVED\n' "$label"; MFAIL=1 ;;
      1) if [ -z "$bad" ]; then printf '  ok    %-62s convicted\n' "$label"
         else printf '  XX    %-62s not convicted, no FAIL line under:%s\n' "$label" "$bad"; MFAIL=1; fi ;;
      *) printf '  ERR   %-62s harness error (rc=%s), not a conviction\n' "$label" "$r"; MFAIL=1 ;;
    esac
  }
  mutate 'the tool capture merges stderr into stdout (2>&1)'    's@^(  out=\$\("\$tool" "\$ldb" "\$desc" )2>>"\$LOG"\)@\12>\&1)@'
  mutate 'the prefs-exists guard removed'                       '/^seed_aurora_installer\(\) \{$/,/^\}$/{/^  \[ -f "\$xml" \] && return$/d}'
  mutate 'the numeric-uid case removed'                         '/^seed_aurora_installer\(\) \{$/,/^\}$/{/^  case "\$auid" in/d}'
  mutate 'the chown given a fixed uid instead of the stat result' '/^seed_aurora_installer\(\) \{$/,/^\}$/{s@chown "\$auid:\$auid"@chown "1000:1000"@}'
  mutate 'L1 restorecon -R back in place of the chcons'           '/^seed_aurora_installer\(\) \{$/,/^\}$/{s@^  chcon -h "\$ctx" "\$xml" .*@  restorecon -R "$spdir" 2>>"$LOG"@;/^  if \[ -n "\$made" \]; then$/,/^  fi$/d}'
  mutate 'L2 the shared_prefs dir chcon even when it pre-existed' '/^seed_aurora_installer\(\) \{$/,/^\}$/{s@^  if \[ -n "\$made" \]; then$@  if :; then@}'
  mutate 'L3 the dir-context check removed'                       '/^seed_aurora_installer\(\) \{$/,/^\}$/{/^    \*\) echo "\[roamd\] WARN seed-aurora: unexpected dir context/d}'
  mutate 'L4 the context read from shared_prefs, not the pkg dir' '/^seed_aurora_installer\(\) \{$/,/^\}$/{s@^(  ctx=\$\(stat -c .%C. )"\$adir"@\1"$spdir"@}'
  mutate 'L5 the prefs-file chcon dropped'                        '/^seed_aurora_installer\(\) \{$/,/^\}$/{/^  chcon -h "\$ctx" "\$xml" /d}'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
