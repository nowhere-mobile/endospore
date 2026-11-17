#!/usr/bin/env bash
# test-odrestore-label-progress.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's label step writes a progress line
# while the CE/DE relabel still labels files, so only a label step that stops advancing reaches the daemon's 150 s
# stop (NWP-20261202-32).
#
# WHY THIS IS COMMITTED. The 2026-11-01 decision (h50 #1, docs/product-decisions.md) has the login daemon stop a
# worker op it gave up on, and gives odrestore's label step the copy's rule: "The label step gets the same rule,
# counted in files labelled". The copy got its progress lines first (od_watched, NWP-20261124-03); the label step
# after it (reown_restored, then od_relabel) still ran silent. The daemon resets its stall clock only when the
# progress line changes (core/agent main.go runWorkerHeld), so a large app dir whose relabel needs more than 150 s
# was stopped while it still labelled files. od_label_watched runs the pair in the background with OD_LABEL_COUNT
# naming a count file: relabel_restored's chcon walk appends each batch's file count there, and the watcher reads the
# total between polls and writes a line only when it grew. Since NWP-20261207-05 reown_restored's chown and the
# external volumes' restorecon are counted too; this suite stubs reown_restored and runs the CE volume only, so
# test-odrestore-handback-progress.sh covers those two walks.
#
# This suite EXECUTES the real extracted mi_path, relabel_restored, od_relabel, od_label_done, od_label_watched,
# cutoff_prog and odrestore arm under every shell found (the device's is mksh). PATH stubs `find`, `chcon` and `stat`
# stand in for toybox; the find stub runs the REAL `sh -c` of the counted walk over batches of fake names. A wrapper
# over od_label_done counts the reads, and the find stub releases batch i only after read i; the wrapper returns only
# after that batch ended. So the batches move in lockstep with the reads (never with sleeps), and no assertion depends
# on how many polls land in a stretch of time:
#   L1 GROWTH: 3 batches, each after a read -> at least 3 progress lines after the volume's own line
#   L2 NO GROWTH: the label step runs for 3 reads with no batch -> no line after the volume's own
#   L3 ORDER and STATUS: the hold is in place at every read and when the walk starts, and gone after the label step;
#      od_label_watched returns the relabel's status (1 for an unexpected dir context), background and foreground
#   L4 UNSET: relabel_restored with OD_LABEL_COUNT unset or empty runs main's walk, `-exec chcon -h <ctx> {} +`
#   L5 $STATE unwritable: the pair runs in the foreground, main's walk, no count file, no read
#   L6 nothing is left in $STATE; no progress line or count-file line names the package or a path; the
#      `relabelled <n> restored entr(ies)` line is unchanged
#
#   bash test-odrestore-label-progress.sh              # the cases, under every shell found
#   bash test-odrestore-label-progress.sh --mutate     # ... plus mutants that must each CONVICT under each shell
#
# Pure logic -- no device. The functions and the arm are EXTRACTED by anchor and re-rooted to a temp tree.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, driver, stub and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

UID_=15
PKG=com.example.game
APPID=10234
OWNED=$((UID_ * 100000 + APPID))
CTX='u:object_r:app_data_file:s0:c15,c256,c512,c768'
NENT=6
# bash has no `print`; mi_path uses it (mksh's builtin) only for an escaped mountinfo line.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH PKGOK ARM ARMR PROG MIP RR ODR ODRR OLD OLW n sh L R HARN="" CE D H
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  atleast() { [ "$1" -ge "$2" ]; }
  has() { grep -qF -- "$2" "$1" 2>/dev/null; }
  clean() { [ -f "$1" ] && ! grep -qF -- "$PKG" "$1" && ! grep -qF / "$1"; }
  digits() { [ -f "$1" ] && ! grep -qv '^[0-9][0-9]*$' "$1"; }

  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  ARM=$(arm_of "$f" odrestore)
  PROG=$(anchor_of "$f" 'cutoff_prog() {')
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  MIP=$(anchor_of "$f" 'mi_path() {')
  RR=$(anchor_of "$f" 'relabel_restored() {')
  ODR=$(anchor_of "$f" 'od_relabel() {')
  # od_label_done and od_label_watched are absent before NWP-20261202-32: define nothing, so the cases RUN against
  # that code and fail.
  OLD=$(anchor_of "$f" 'od_label_done() {')
  OLW=$(anchor_of "$f" 'od_label_watched() {')
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  case "$PROG" in *'NOWHERE_PROGRESS.tmp'*'mv -f'*) ;; *) echo "EXTRACTION FAILED: cutoff_prog in $f" >&2; return 2 ;; esac
  case "$MIP" in *'sed'*) ;; *) echo "EXTRACTION FAILED: mi_path in $f" >&2; return 2 ;; esac
  case "$RR" in *'stat -c '\''%C'\'' "$d"'*'-exec chcon -h "$ctx" {} +'*'relabelled $n restored entr(ies)'*) ;; *) echo "EXTRACTION FAILED: relabel_restored in $f" >&2; return 2 ;; esac
  case "$ODR" in *'/data/media/*)'*'restorecon -R "$2"'*'relabel_restored "$2"'*) ;; *) echo "EXTRACTION FAILED: od_relabel in $f" >&2; return 2 ;; esac
  case "$OLD" in ''|*'done < "$1"'*) ;; *) echo "EXTRACTION FAILED: od_label_done in $f" >&2; return 2 ;; esac
  case "$OLW" in ''|*'od_relabel "$vol" "$dst"'*) ;; *) echo "EXTRACTION FAILED: od_label_watched in $f" >&2; return 2 ;; esac
  # The wrapper below counts each read: the real reader is renamed, so a call to od_label_done goes through it.
  [ -z "$OLD" ] || OLD=$(printf '%s\n' "$OLD" | sed '1s/^od_label_done() {$/od_label_done_real() {/')
  ODRR=$(printf '%s\n' "$ODR" | sed 's#^    /data/media/#    $ROOT/data/media/#')
  for n in "$RR" "$ODRR" "$OLD" "$OLW"; do
    [ "$(nleft "$n")" = 0 ] || { echo "RE-ROOT INCOMPLETE: a label-step function holds an absolute /data path" >&2; return 2; }
  done
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/bin" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" \
             "$R/data/user_de/$UID_" "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/sim/reads"; : > "$R/sim/batches"; : > "$R/sim/badctx"; : > "$R/sim/calls"
    : > "$R/sim/findargv"; : > "$R/sim/chcon"; : > "$R/sim/holdseen"; echo grow > "$R/sim/findmode"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    # stat: -c %C prints the app context, or a system one for a dir listed in sim/badctx; -c %u reads sim/owners.
    cat > "$R/bin/stat" <<EOF
#!/bin/sh
case "\$2" in
  %C) if grep -qxF -- "\$3" "$R/sim/badctx"; then echo u:object_r:system_data_file:s0; else echo '$CTX'; fi ;;
  *) awk -v p="\$3" '\$1 == p {print \$2; f=1} END{exit !f}' "$R/sim/owners" ;;
esac
EOF
    # chcon: records the size of each call
    printf '#!/bin/sh\necho "chcon $#" >> "%s"\n' "$R/sim/chcon" > "$R/bin/chcon"
    # find: records its argv (tab-joined) and, for the walk's -exec, the count file it was handed. A -print walk
    # prints NENT entries. An -exec walk that runs `sh` is the counted walk: in mode grow it runs batch i (2 names)
    # after read i and records it in sim/batches, then waits for the read that sees the last batch; in mode flat it
    # waits for 3 reads and labels nothing. Any other -exec runs once over NENT names. 60 s safety exit.
    cat > "$R/bin/find" <<EOF
#!/usr/bin/env bash
S="$R/sim"
{ for a in "\$@"; do printf '%s\t' "\$a"; done; echo; } >> "\$S/findargv"
d="\$1"; cmd=(); ex=0; pr=0
for a in "\$@"; do
  if [ "\$ex" = 1 ]; then [ "\$a" = "{}" ] && ex=2 || cmd+=("\$a"); continue; fi
  case "\$a" in -exec) [ "\$ex" = 0 ] && ex=1 ;; -print) pr=1 ;; esac
done
if [ "\$pr" = 1 ]; then i=0; while [ "\$i" -lt $NENT ]; do echo "\$d/e\$i"; i=\$((i+1)); done; exit 0; fi
[ "\${#cmd[@]}" -gt 0 ] || exit 0
echo "\${OD_LABEL_COUNT-unset}" > "\$S/countenv"
[ -d "\$HOLD" ] && echo held > "\$S/holdatfind" || echo gone > "\$S/holdatfind"
waitr() {
  local i=0
  while [ "\$(grep -c . "\$S/reads")" -lt "\$1" ]; do
    i=\$((i+1)); [ "\$i" -le 600 ] || { : > "\$S/timeout"; return 1; }
    sleep 0.1
  done
}
if [ "\${cmd[0]}" = sh ]; then
  case "\$(cat "\$S/findmode")" in
    grow) for k in 1 2 3; do waitr "\$k" || break; "\${cmd[@]}" "\$d/b\${k}a" "\$d/b\${k}b"; echo "\$k" >> "\$S/batches"; done
          waitr 4 ;;
    flat) waitr 3 ;;
  esac
  [ -n "\${OD_LABEL_COUNT:-}" ] && [ -f "\$OD_LABEL_COUNT" ] && cat "\$OD_LABEL_COUNT" > "\$S/countseen"
else
  "\${cmd[@]}" \$(i=0; while [ "\$i" -lt $NENT ]; do echo "\$d/e\$i"; i=\$((i+1)); done)
fi
exit 0
EOF
    chmod +x "$R/bin/stat" "$R/bin/chcon" "$R/bin/find"
  }
  # plant <vol>: a hold for $PKG on that volume and an app-owned (empty) destination
  plant() {
    mkdir -p "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files" "$R/data/$1/$PKG"
    echo payload > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/f.txt"
    echo "$R/data/$1/$PKG $OWNED" >> "$R/sim/owners"
  }
  # driver <root> <state dir or file> <body>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf '%s\n' "$PRINT_SHIM"
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nuid=%s\nPATH='%s':\"\$PATH\"\nHOLD='%s'\nexport PATH HOLD\n" \
             "$1" "$1/roam.log" "$1/res" "$UID_" "$1/bin" "$1/data/$CE/com.nowhere.chooser/.nowhere-odhold/$PKG"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\n" \
             "$1/data/user/$UID_" "$PKG" "$2"
      printf "NOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" "$1/prog"
      cat <<'EOF'
date() { echo DATE; }
restorecon() { echo "restorecon $*" >> "$ROOT/sim/calls"; }
am() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
grant_perms_for() { :; }
keystore_register() { :; }
pm() { case "$*" in "list packages -U "*) echo "package:$srcunit uid:1110234" ;; esac; return 0; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
cp() { command cp -R "$2" "$3"; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03
od_watched() { shift; "$@" 2>&1; }
vpn_preconsent_off() { :; }   # NWP-20261202-03
reown_restored() {
  if [ -d "$HOLD" ]; then echo "reown $1 held" >> "$ROOT/sim/calls"; else echo "reown $1 gone" >> "$ROOT/sim/calls"; fi
  return 0
}
# the reader, counted: the read is done first, then the hold's state and the read are recorded; in mode grow the
# call returns only after the batch this read released has ended, so the next read sees it (60 s safety exit)
od_label_done() {
  local t c i=0
  t=$(od_label_done_real "$1")
  if [ -d "$HOLD" ]; then echo held >> "$ROOT/sim/holdseen"; else echo gone >> "$ROOT/sim/holdseen"; fi
  echo x >> "$ROOT/sim/reads"
  c=$(grep -c . "$ROOT/sim/reads")
  if [ "$(cat "$ROOT/sim/findmode")" = grow ] && [ "$c" -le 3 ]; then
    while [ "$(grep -c . "$ROOT/sim/batches")" -lt "$c" ]; do
      i=$((i+1)); [ "$i" -le 600 ] || { : > "$ROOT/sim/timeout"; break; }
      sleep 0.1
    done
  fi
  echo "$t"
}
EOF
      printf '%s\n' "$ODH" "$PKGOK" "$PROG" "$MIP" "$RR" "$ODRR" "$OLD" "$OLW"
      printf '%s\n' "$3"
    } > "$1/driver.sh"
  }
  run() {  # run <sh> <state dir or file> <body>
    local e
    driver "$R" "$2" "$3"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  ARMBODY=$(printf 'case "$op" in\n%s\nesac\n' "$ARMR")
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  ticks() { local l; l=$(val "$R/prog"); case "$l" in "cutoff od "*) echo $(( ${l#cutoff od } - 1 )) ;; *) echo -1 ;; esac; }
  reads() { grep -c . "$R/sim/reads"; }
  left() { ls -A "$R/state" | tr '\n' ' '; }
  execargv() { grep -F "$(printf '\t-exec\t')" "$R/sim/findargv"; }
  CE="user/$UID_"
  # direct <dst>: a body that calls od_label_watched on the CE volume and records its status (none when it is absent)
  direct() {
    printf 'if command -v od_label_watched >/dev/null 2>&1; then od_label_watched "$ROOT/data/%s" '"'%s'"'; echo $? > "$ROOT/sim/rc"; fi\n' "$CE" "$1"
  }
  RLOG="relabelled $NENT restored entr(ies) of $PKG to the app's context (NWP-20261005-03)"

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh L1: 3 chcon batches, each after a read -> a progress line per growth =="
    mkroot; plant "$CE"; D="$R/data/$CE/$PKG"; H="$R/data/$CE/com.nowhere.chooser/.nowhere-odhold/$PKG"
    run "$sh" "$R/state" "$ARMBODY"
    chk "$L L1 at least 3 progress lines after the volume's own" atleast "$(ticks)" 3
    chk "$L L1 the walk never hit its safety exit" absent "$R/sim/timeout"
    chk "$L L1 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L L1 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L L1 the 3 batches ran chcon" eqv "$(grep -c '^chcon 4$' "$R/sim/chcon")" 3
    chk "$L L3 the hold is in place at every read" eqv "$(sort -u "$R/sim/holdseen")" held
    chk "$L L3 the hold is in place when the walk starts" eqv "$(val "$R/sim/holdatfind")" held
    chk "$L L3 reown ran on \$dst with the hold in place" has "$R/sim/calls" "reown $D held"
    chk "$L L3 the hold is gone after the label step" absent "$H"
    chk "$L L6 no count file is left in \$STATE (L1)" eqv "$(left)" ""
    chk "$L L6 the progress line names no package and no path" clean "$R/prog"
    chk "$L L6 the count file held digits only" digits "$R/sim/countseen"
    chk "$L L6 the count file names no package and no path" clean "$R/sim/countseen"
    chk "$L L6 the relabelled line is unchanged" has "$R/roam.log" "$RLOG"

    say "== $sh L2: the label step runs for 3 reads with no batch -> no line after the volume's own =="
    mkroot; plant "$CE"; echo flat > "$R/sim/findmode"
    run "$sh" "$R/state" "$ARMBODY"
    chk "$L L2 the progress line is still the volume's own" eqv "$(val "$R/prog")" "cutoff od 1"
    chk "$L L2 the count was read at least 3 times" atleast "$(reads)" 3
    chk "$L L2 the walk never hit its safety exit" absent "$R/sim/timeout"
    chk "$L L2 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L L6 no count file is left in \$STATE (L2)" eqv "$(left)" ""

    say "== $sh L3: the relabel fails (unexpected dir context) -> od_label_watched returns its status =="
    mkroot; mkdir -p "$R/data/$CE/$PKG"; D="$R/data/$CE/$PKG"; echo "$D" > "$R/sim/badctx"; echo flat > "$R/sim/findmode"
    run "$sh" "$R/state" "$(direct "$D")"
    chk "$L L3 the background form returns the relabel's 1" eqv "$(val "$R/sim/rc")" 1
    chk "$L L3 the relabel logged the unexpected context" has "$R/roam.log" "unexpected dir context"
    chk "$L L6 no count file is left in \$STATE (L3)" eqv "$(left)" ""
    mkroot; mkdir -p "$R/data/$CE/$PKG"; D="$R/data/$CE/$PKG"; echo "$D" > "$R/sim/badctx"; : > "$R/statefile"
    run "$sh" "$R/statefile" "$(direct "$D")"
    chk "$L L3 the foreground form returns the relabel's 1" eqv "$(val "$R/sim/rc")" 1

    say "== $sh L4: OD_LABEL_COUNT unset or empty -> main's walk =="
    for n in unset empty; do
      mkroot; mkdir -p "$R/data/$CE/$PKG"; D="$R/data/$CE/$PKG"
      if [ "$n" = unset ]; then
        run "$sh" "$R/state" "unset OD_LABEL_COUNT; relabel_restored '$D'"
      else
        run "$sh" "$R/state" "OD_LABEL_COUNT=; export OD_LABEL_COUNT; relabel_restored '$D'"
      fi
      chk "$L L4 ($n) the walk is -exec chcon -h <ctx> {} +" eqv "$(execargv)" "$(printf '%s\t' "$D" -xdev ! -context "$CTX" -exec chcon -h "$CTX" {} +)"
      chk "$L L4 ($n) chcon ran over the entries" eqv "$(val "$R/sim/chcon")" "chcon $((NENT + 2))"
      chk "$L L4 ($n) the relabelled line is unchanged" has "$R/roam.log" "$RLOG"
    done

    say "== $sh L5: \$STATE unwritable -> the pair runs in the foreground, main's walk =="
    mkroot; plant "$CE"; D="$R/data/$CE/$PKG"; : > "$R/statefile"
    run "$sh" "$R/statefile" "$ARMBODY"
    chk "$L L5 reown ran on \$dst" has "$R/sim/calls" "reown $D held"
    chk "$L L5 the walk is main's -exec chcon" eqv "$(execargv)" "$(printf '%s\t' "$D" -xdev ! -context "$CTX" -exec chcon -h "$CTX" {} +)"
    chk "$L L5 the walk had no count file" eqv "$(val "$R/sim/countenv")" unset
    chk "$L L5 no read" eqv "$(reads)" 0
    chk "$L L5 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L L5 the relabelled line is unchanged" has "$R/roam.log" "$RLOG"
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line) =="
# xform <fn> <from> <to>: inside function <fn> only, the line exactly <from> becomes <to> (the token DEL drops it).
xform() {
  awk -v FN="$1() {" -v FR="$2" -v TO="$3" '
    $0 == FN { fn = 1 }
    fn && $0 == FR { hit = 1; if (TO != "DEL") print TO; next }
    { print }
    fn && $0 == "}" { fn = 0 }
    END { exit !hit }
  ' "$SUT"
}
MF=0
mutate() {  # mutate <id> <label> <convicting assertion> <fn> <from> <to>
  local id="$1" label="$2" by="$3" m out mrc s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! xform "$4" "$5" "$6" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (nothing changed): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $by"*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED by $by under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted by $by: $id $label"; fi
}
L_TICK='    if [ "$cur" -gt "$last" ]; then cutoff_prog od; last=$cur; fi'
L_BG='  ( export OD_LABEL_COUNT="$cnt" OD_LABEL_LOG="$LOG"; reown_restored "$dst"; od_relabel "$vol" "$dst" ) &'
L_WAIT='  wait "$pid"; rc=$?'
L_RM='  rm -f "$cnt"'
L_IF='  if [ -n "${OD_LABEL_COUNT:-}" ]; then'
# The control: replacing a line with itself must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
if ! xform od_label_watched "$L_TICK" "$L_TICK" > "$c" || ! cmp -s "$SUT" "$c"; then
  echo "  FAIL  the transform does not reproduce $SUT (the anchors moved)"; MF=$((MF+1))
fi
mutate m1 "a line on every poll instead of on growth" L2 od_label_watched "$L_TICK" '    cutoff_prog od; last=$cur'
mutate m2 "no line on growth" L1 od_label_watched "$L_TICK" '    if [ "$cur" -gt "$last" ]; then last=$cur; fi'
mutate m3 "the count file is not exported to the walk" L1 od_label_watched "$L_BG" \
  '  ( OD_LABEL_COUNT="$cnt" OD_LABEL_LOG="$LOG"; reown_restored "$dst"; od_relabel "$vol" "$dst" ) &'
mutate m4 "growth compared with -ge" L2 od_label_watched "$L_TICK" '    if [ "$cur" -ge "$last" ]; then cutoff_prog od; last=$cur; fi'
mutate m5 "the job's status is not waited for" L3 od_label_watched "$L_WAIT" '  rc=0'
mutate m6 "the counted walk runs with the count unset" L4 relabel_restored "$L_IF" '  if :; then'
mutate m7 "the count file is not removed" L6 od_label_watched "$L_RM" DEL

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
