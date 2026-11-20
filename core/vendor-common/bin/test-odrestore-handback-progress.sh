#!/usr/bin/env bash
# test-odrestore-handback-progress.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's whole hand-back feeds the
# daemon's stall clock: reown_restored's chown and the external volumes' restorecon are counted like the CE/DE chcon
# walk, so a hand-back that still labels files is not given up on at 150 s (NWP-20261207-05).
#
# WHY THIS IS COMMITTED. Backlog row 'An app with a large data hold never gets its data back: its odrestore goes
# silent for 150 s after the copy, the daemon gives up and stops it, the hold is kept, and every retry copies the
# whole hold again'. The 2026-11-01 decision (h50 #1, docs/product-decisions.md) gives the label step the copy's rule:
# "The label step gets the same rule, counted in files labelled". The daemon resets its stall clock only when the
# progress line changes (core/agent main.go roamStallBudget, 150 s). od_label_watched (NWP-20261202-32) counted only
# relabel_restored's chcon walk; reown_restored's `chown -R` and od_relabel's external `restorecon -R` wrote no
# count, so a large hold's chown alone could outlast the budget and be stopped. Now both run as counted batches
# into the same count file: od_walk's `find -print0 | xargs -0 -r -n 256 sh -c` (NWP-20261209-04; `find -exec sh -c`
# before it), whose failure the pair now reports as 2.
#
# This suite EXECUTES the real extracted od_walk, reown_restored, od_relabel, relabel_restored, mi_path,
# od_label_done, od_label_watched and cutoff_prog under every shell found (the device's is mksh). PATH stubs `find`,
# `xargs`, `chown`, `chcon`, `restorecon` and `stat` stand in for toybox; the xargs stub runs od_walk's REAL `sh -c`
# batch script over the batches of a counted walk. A
# wrapper over od_label_done counts the reads; a walk in mode grow releases batch k only after read k, and the
# wrapper returns only after that batch ended. So the batches move in lockstep with the reads, never with sleeps:
#   H1 CE, the reown grows: 3 chown batches, each after a read -> at least 3 progress lines; each chown call is
#      `chown -h <uid*100000+appid>:<same> <2 names>`; the `reowned restored` line is unchanged
#   H2 EXTERNAL (data/media/<u>/Android/data): 3 restorecon batches after reads -> at least 3 progress lines; each
#      call is `restorecon <2 names>`, no -R
#   H3 NO GROWTH: the chown walk runs for 3 reads with no batch -> no progress line at all
#   H4 PLAIN: OD_LABEL_COUNT unset or empty -> reown_restored runs exactly one `chown -R T:T <dir>` and no find;
#      od_relabel on an external dir runs od_walk's bounded restorecon walk, uncounted (NWP-20261209-04: was one
#      `restorecon -R <dir>`, whose failure od_label_watched's foreground form could not see)
#   H5 UNRESOLVABLE app id: reown_restored returns 1, no chown, no walk, no `reowned restored` line
#   H6 the count file holds digits only; no progress line or count line names the package or a path; nothing is
#      left in $STATE (the count file and od_walk's find-status file); od_label_watched returns od_relabel's status
#      (1 for an unexpected CE dir context), and 2 when a walk failed (NWP-20261209-04: find's status is read now),
#      with no success line of the pair in $LOG
#
#   bash test-odrestore-handback-progress.sh              # the cases, under every shell found
#   bash test-odrestore-handback-progress.sh --mutate     # ... plus mutants that must each CONVICT under each shell
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree.
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
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 PROG MIP OW RO ROR RR ODR ODRR OLD OLW n sh L R HARN="" CE EXT D E want k
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  atleast() { [ "$1" -ge "$2" ]; }
  has() { grep -qF -- "$2" "$1" 2>/dev/null; }
  hasnot() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
  clean() { [ -f "$1" ] && ! grep -qF -- "$PKG" "$1" && ! grep -qF / "$1"; }
  digits() { [ -s "$1" ] && ! grep -qv '^[0-9][0-9]*$' "$1"; }

  PROG=$(anchor_of "$f" 'cutoff_prog() {')
  MIP=$(anchor_of "$f" 'mi_path() {')
  OW=$(anchor_of "$f" 'od_walk() {')
  RO=$(anchor_of "$f" 'reown_restored() {')
  RR=$(anchor_of "$f" 'relabel_restored() {')
  ODR=$(anchor_of "$f" 'od_relabel() {')
  OLD=$(anchor_of "$f" 'od_label_done() {')
  OLW=$(anchor_of "$f" 'od_label_watched() {')
  # The shapes of NWP-20261209-04: every counted walk is an od_walk call.
  case "$PROG" in *'NOWHERE_PROGRESS.tmp'*'mv -f'*) ;; *) echo "EXTRACTION FAILED: cutoff_prog in $f" >&2; return 2 ;; esac
  case "$MIP" in *'sed'*) ;; *) echo "EXTRACTION FAILED: mi_path in $f" >&2; return 2 ;; esac
  case "$OW" in *'done < /proc/self/mountinfo'*'find "$root" "$@" -print0'*'xargs -0 -r -n 256 sh -c'*) ;; *) echo "EXTRACTION FAILED: od_walk in $f" >&2; return 2 ;; esac
  case "$RO" in *'/data/system/packages.list'*'return 1'*'od_walk none '*'chown'*'"$pkgdir"'*'chown -R "$target:$target" "$pkgdir" 2>> "$LOG"'*'reowned restored'*'return 0'*) ;; *) echo "EXTRACTION FAILED: reown_restored in $f" >&2; return 2 ;; esac
  case "$RR" in *'stat -c '\''%C'\'' "$d"'*'od_walk none 3 chcon -h "$ctx"'*'relabelled $n restored entr(ies)'*) ;; *) echo "EXTRACTION FAILED: relabel_restored in $f" >&2; return 2 ;; esac
  case "$ODR" in *'/data/media/*)'*'od_walk prune '*'restorecon'*'"$2"'*'relabel_restored "$2"'*) ;; *) echo "EXTRACTION FAILED: od_relabel in $f" >&2; return 2 ;; esac
  case "$OLD" in *'done < "$1"'*) ;; *) echo "EXTRACTION FAILED: od_label_done in $f" >&2; return 2 ;; esac
  case "$OLW" in *'reown_restored "$dst"; r=$?'*'od_relabel "$vol" "$dst"; r=$?'*'cutoff_prog od'*) ;; *) echo "EXTRACTION FAILED: od_label_watched in $f" >&2; return 2 ;; esac
  # The wrapper below counts each read: the real reader is renamed, so a call to od_label_done goes through it.
  OLD=$(printf '%s\n' "$OLD" | sed '1s/^od_label_done() {$/od_label_done_real() {/')
  ROR=$(printf '%s\n' "$RO" | sed 's# /data/system/packages.list# $ROOT/data/system/packages.list#')
  ODRR=$(printf '%s\n' "$ODR" | sed 's#^    /data/media/#    $ROOT/data/media/#')
  # od_walk's prune reads the mount table: the case root's own (empty) one, so no host mount reaches a walk.
  OW=$(printf '%s\n' "$OW" | sed 's#done < /proc/self/mountinfo$#done < "$ROOT/sim/mountinfo"#')
  case "$OW" in *'done < "$ROOT/sim/mountinfo"'*) ;; *) echo "RE-ROOT FAILED: od_walk's mountinfo" >&2; return 2 ;; esac
  for n in "$OW" "$ROR" "$RR" "$ODRR" "$OLD" "$OLW"; do
    [ "$(nleft "$n")" = 0 ] || { echo "RE-ROOT INCOMPLETE: a hand-back function holds an absolute /data path" >&2; return 2; }
  done

  mkroot() {
    local t
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/bin" "$R/state" "$R/data/system" "$R/data/user/$UID_/$PKG" \
             "$R/data/media/$UID_/Android/data/$PKG"
    : > "$R/sim/reads"; : > "$R/sim/batches"; : > "$R/sim/badctx"; : > "$R/sim/calls"; : > "$R/sim/findargv"
    : > "$R/sim/mountinfo"; : > "$R/sim/walkargv"
    echo none > "$R/sim/mode.chown"; echo once > "$R/sim/mode.chcon"; echo none > "$R/sim/mode.restorecon"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    # stat: -c %C prints the app context, or a system one for a dir listed in sim/badctx.
    cat > "$R/bin/stat" <<EOF
#!/bin/sh
if grep -qxF -- "\$3" "$R/sim/badctx"; then echo u:object_r:system_data_file:s0; else echo '$CTX'; fi
EOF
    # chown, chcon, restorecon: each call is one line of sim/calls, its name and argv
    for t in chown chcon restorecon; do
      printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$t" "$R/sim/calls" > "$R/bin/$t"
    done
    # find: records its argv (tab-joined). A -print listing prints NENT entries and exits 0. A -print0 walk (od_walk's)
    # writes its root, NUL-terminated, for the xargs stub, and exits with sim/findrc when present, else 0.
    cat > "$R/bin/find" <<EOF
#!/usr/bin/env bash
S="$R/sim"
{ for a in "\$@"; do printf '%s\t' "\$a"; done; echo; } >> "\$S/findargv"
d="\$1"; pr=0; p0=0
for a in "\$@"; do case "\$a" in -print) pr=1 ;; -print0) p0=1 ;; esac; done
if [ "\$pr" = 1 ]; then i=0; while [ "\$i" -lt $NENT ]; do echo "\$d/e\$i"; i=\$((i+1)); done; exit 0; fi
[ "\$p0" = 1 ] && printf '%s\0' "\$d"
[ -f "\$S/findrc" ] && exit "\$(cat "\$S/findrc")"
exit 0
EOF
    # xargs: od_walk's `xargs -0 -r -n 256 sh -c SCRIPT od_walk K W1 W2 W3`; any other argv is recorded in sim/xargsbad
    # and fails. It reads the walk's root (the first NUL name) and drains the rest, records the walk's words
    # (K W1 W2 W3, tab-joined) in sim/walkargv, and runs the REAL batch script once per batch. The walk is named by
    # its tool W1 (chcon, chown, restorecon); its mode is sim/mode.<walk>: grow runs batch k (2 names) after read k
    # and records it in sim/batches, then waits for the read that sees the last batch; flat waits for 3 reads and
    # runs nothing; once runs one batch of 2 names at once; none runs nothing. A batch that fails makes it exit 123,
    # as toybox xargs does; sim/xargsrc.<walk>, when present, is its exit status. 60 s safety exit (sim/timeout).
    cat > "$R/bin/xargs" <<EOF
#!/usr/bin/env bash
S="$R/sim"
if [ "\$#" -lt 10 ] || [ "\$1 \$2 \$3 \$4 \$5 \$6 \$8" != "-0 -r -n 256 sh -c od_walk" ]; then
  { for a in "\$@"; do printf '%s\t' "\$a"; done; echo; } >> "\$S/xargsbad"; cat > /dev/null; exit 2
fi
shift 4; cmd=("\$@")
d=; IFS= read -r -d '' d; cat > /dev/null
printf '%s\t' "\${cmd[@]:4}" >> "\$S/walkargv"; echo >> "\$S/walkargv"
waitr() {
  local i=0
  while [ "\$(grep -c . "\$S/reads")" -lt "\$1" ]; do
    i=\$((i+1)); [ "\$i" -le 600 ] || { : > "\$S/timeout"; return 1; }
    sleep 0.1
  done
}
rc=0; w="\${cmd[5]}"
case "\$(cat "\$S/mode.\$w" 2>/dev/null)" in
  grow) : > "\$S/growing"
        for k in 1 2 3; do waitr "\$k" || break; "\${cmd[@]}" "\$d/b\${k}a" "\$d/b\${k}b" || rc=123; echo "\$k" >> "\$S/batches"; done
        waitr 4 ;;
  flat) waitr 3 ;;
  once) "\${cmd[@]}" "\$d/o1a" "\$d/o1b" || rc=123 ;;
esac
[ -n "\${OD_LABEL_COUNT:-}" ] && [ -f "\$OD_LABEL_COUNT" ] && cat "\$OD_LABEL_COUNT" > "\$S/countseen"
[ -f "\$S/xargsrc.\$w" ] && exit "\$(cat "\$S/xargsrc.\$w")"
exit "\$rc"
EOF
    chmod +x "$R/bin/stat" "$R/bin/chown" "$R/bin/chcon" "$R/bin/restorecon" "$R/bin/find" "$R/bin/xargs"
  }
  # driver <root> <state dir> <body>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf '%s\n' "$PRINT_SHIM"
      printf "ROOT='%s'\nLOG='%s'\nuid=%s\nPATH='%s':\"\$PATH\"\nexport PATH\n" "$1" "$1/roam.log" "$UID_" "$1/bin"
      printf "STATE='%s'\nNOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" "$2" "$1/prog"
      cat <<'EOF'
# the reader, counted: the read is done first, then recorded; when a walk of the case grows (sim/grow), the call
# returns only after the batch this read released has ended, so the next read sees it (60 s safety exit). When no
# grow walk has started 3 s into a read (the code under test runs no such walk), it returns without waiting.
od_label_done() {
  local t c i=0
  t=$(od_label_done_real "$1")
  echo x >> "$ROOT/sim/reads"
  c=$(grep -c . "$ROOT/sim/reads")
  if [ -f "$ROOT/sim/grow" ] && [ ! -f "$ROOT/sim/timeout" ] && [ "$c" -le 3 ]; then
    while [ "$(grep -c . "$ROOT/sim/batches")" -lt "$c" ]; do
      i=$((i+1)); [ "$i" -le 600 ] || { : > "$ROOT/sim/timeout"; break; }
      [ "$i" -le 30 ] || [ -f "$ROOT/sim/growing" ] || break
      sleep 0.1
    done
  fi
  echo "$t"
}
EOF
      printf '%s\n' "$PROG" "$MIP" "$OW" "$ROR" "$RR" "$ODRR" "$OLD" "$OLW"
      printf '%s\n' "$3"
    } > "$1/driver.sh"
  }
  run() {  # run <sh> <body>
    local e
    driver "$R" "$R/state" "$2"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  ticks() { local l; l=$(val "$R/prog"); case "$l" in "cutoff od "*) echo "${l#cutoff od }" ;; *) echo 0 ;; esac; }
  reads() { grep -c . "$R/sim/reads"; }
  left() { ls -A "$R/state" | tr '\n' ' '; }
  calls() { grep "^$1 " "$R/sim/calls"; }
  # watched <vol> <dst>: a body that runs od_label_watched and records its status
  watched() { printf 'od_label_watched '"'%s' '%s'"'; echo $? > "$ROOT/sim/rc"\n' "$1" "$2"; }
  RLOG="[roamd] reowned restored $PKG -> $OWNED (user $UID_)"

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh H1: CE, 3 chown batches, each after a read -> a progress line per growth =="
    mkroot; CE="$R/data/user/$UID_"; D="$CE/$PKG"; echo grow > "$R/sim/mode.chown"; : > "$R/sim/grow"
    run "$sh" "$(watched "$CE" "$D")"
    chk "$L H1 at least 3 progress lines" atleast "$(ticks)" 3
    chk "$L H1 the walks never hit their safety exit" absent "$R/sim/timeout"
    chk "$L H1 every walk is xargs -0 -r -n 256 sh -c <batch script> od_walk" absent "$R/sim/xargsbad"
    chk "$L H1 the 3 chown batches ran" eqv "$(grep -c . "$R/sim/batches")" 3
    want=""; for k in 1 2 3; do want="$want${want:+
}chown -h $OWNED:$OWNED $D/b${k}a $D/b${k}b"; done
    chk "$L H1 each chown call is chown -h <owner>:<owner> <2 names>" eqv "$(calls chown)" "$want"
    chk "$L H1 the chcon walk ran its batch" eqv "$(calls chcon)" "chcon -h $CTX $D/o1a $D/o1b"
    chk "$L H1 the reowned restored line is unchanged" has "$R/roam.log" "$RLOG"
    chk "$L H6 od_label_watched returns the CE relabel's 0" eqv "$(val "$R/sim/rc")" 0
    chk "$L H6 no count file is left in \$STATE (H1)" eqv "$(left)" ""
    chk "$L H6 the progress line names no package and no path (H1)" clean "$R/prog"
    chk "$L H6 the count file held digits only (H1)" digits "$R/sim/countseen"
    chk "$L H6 the count file names no package and no path (H1)" clean "$R/sim/countseen"

    say "== $sh H2: external, 3 restorecon batches, each after a read -> a progress line per growth =="
    mkroot; EXT="$R/data/media/$UID_/Android/data"; E="$EXT/$PKG"
    echo once > "$R/sim/mode.chown"; echo grow > "$R/sim/mode.restorecon"; : > "$R/sim/grow"
    run "$sh" "$(watched "$EXT" "$E")"
    chk "$L H2 at least 3 progress lines" atleast "$(ticks)" 3
    chk "$L H2 the walks never hit their safety exit" absent "$R/sim/timeout"
    chk "$L H2 every walk is xargs -0 -r -n 256 sh -c <batch script> od_walk" absent "$R/sim/xargsbad"
    want=""; for k in 1 2 3; do want="$want${want:+
}restorecon $E/b${k}a $E/b${k}b"; done
    chk "$L H2 each restorecon call is restorecon <2 names>, no -R" eqv "$(calls restorecon)" "$want"
    chk "$L H2 the external dir took no chcon" eqv "$(calls chcon)" ""
    chk "$L H2 the reown ran its batch" eqv "$(calls chown)" "chown -h $OWNED:$OWNED $E/o1a $E/o1b"
    chk "$L H6 od_label_watched returns the external walk's 0" eqv "$(val "$R/sim/rc")" 0
    chk "$L H6 no count file is left in \$STATE (H2)" eqv "$(left)" ""
    chk "$L H6 the progress line names no package and no path (H2)" clean "$R/prog"
    chk "$L H6 the count file held digits only (H2)" digits "$R/sim/countseen"
    chk "$L H6 the count file names no package and no path (H2)" clean "$R/sim/countseen"

    say "== $sh H3: the chown walk runs for 3 reads with no batch -> no progress line =="
    mkroot; CE="$R/data/user/$UID_"; D="$CE/$PKG"; echo flat > "$R/sim/mode.chown"; echo none > "$R/sim/mode.chcon"
    run "$sh" "$(watched "$CE" "$D")"
    chk "$L H3 no progress line" absent "$R/prog"
    chk "$L H3 the count was read at least 3 times" atleast "$(reads)" 3
    chk "$L H3 the walk never hit its safety exit" absent "$R/sim/timeout"
    chk "$L H6 no count file is left in \$STATE (H3)" eqv "$(left)" ""

    for n in unset empty; do
      say "== $sh H4 ($n): OD_LABEL_COUNT $n -> the plain chown -R, and the restorecon walk uncounted =="
      mkroot; D="$R/data/user/$UID_/$PKG"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.restorecon"
      if [ "$n" = unset ]; then k='unset OD_LABEL_COUNT OD_LABEL_LOG'; else k='OD_LABEL_COUNT=; OD_LABEL_LOG=; export OD_LABEL_COUNT OD_LABEL_LOG'; fi
      run "$sh" "$k; reown_restored '$D'; echo \$? > \"\$ROOT/sim/rc\""
      chk "$L H4 ($n) reown_restored runs exactly one chown -R" eqv "$(val "$R/sim/calls")" "chown -R $OWNED:$OWNED $D"
      chk "$L H4 ($n) reown_restored runs no find" eqv "$(val "$R/sim/findargv")" ""
      chk "$L H4 ($n) reown_restored returns 0" eqv "$(val "$R/sim/rc")" 0
      chk "$L H4 ($n) the reowned restored line is unchanged" has "$R/roam.log" "$RLOG"
      mkroot; EXT="$R/data/media/$UID_/Android/data"; E="$EXT/$PKG"; echo once > "$R/sim/mode.restorecon"
      run "$sh" "$k; od_relabel '$EXT' '$E'; echo \$? > \"\$ROOT/sim/rc\""
      chk "$L H4 ($n) od_relabel runs the bounded restorecon walk on an external dir" eqv "$(val "$R/sim/calls")" "restorecon $E/o1a $E/o1b"
      chk "$L H4 ($n) od_relabel's walk is one find -print0 of the dir" eqv "$(val "$R/sim/findargv")" "$E"$'\t'-print0$'\t'
      chk "$L H4 ($n) od_relabel's walk writes no count" absent "$R/sim/countseen"
      chk "$L H4 ($n) od_relabel returns 0" eqv "$(val "$R/sim/rc")" 0
    done

    say "== $sh H5: the app id is not resolvable -> reown_restored returns 1, no chown, no walk =="
    for n in counted plain; do
      mkroot; D="$R/data/user/$UID_/$PKG"; echo once > "$R/sim/mode.chown"
      echo "com.example.other 10999 0 /data/user/0/com.example.other default none 0 1 1234" > "$R/data/system/packages.list"
      if [ "$n" = counted ]; then k='OD_LABEL_COUNT="$STATE/cnt"; OD_LABEL_LOG="$LOG"; export OD_LABEL_COUNT OD_LABEL_LOG'; else k='unset OD_LABEL_COUNT'; fi
      run "$sh" "$k; reown_restored '$D'; echo \$? > \"\$ROOT/sim/rc\""
      chk "$L H5 ($n) reown_restored returns 1" eqv "$(val "$R/sim/rc")" 1
      chk "$L H5 ($n) no chown ran" eqv "$(val "$R/sim/calls")" ""
      chk "$L H5 ($n) no walk ran" eqv "$(val "$R/sim/findargv")" ""
      chk "$L H5 ($n) no reowned restored line" hasnot "$R/roam.log" "reowned restored"
    done

    say "== $sh H6: od_label_watched returns od_relabel's status, and 2 when a walk failed =="
    mkroot; CE="$R/data/user/$UID_"; D="$CE/$PKG"; echo "$D" > "$R/sim/badctx"; echo once > "$R/sim/mode.chown"
    run "$sh" "$(watched "$CE" "$D")"
    chk "$L H6 an unexpected CE dir context returns the relabel's 1" eqv "$(val "$R/sim/rc")" 1
    chk "$L H6 no count file is left in \$STATE (bad context)" eqv "$(left)" ""
    mkroot; EXT="$R/data/media/$UID_/Android/data"; E="$EXT/$PKG"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.restorecon"
    echo 126 > "$R/sim/xargsrc.restorecon"
    run "$sh" "$(watched "$EXT" "$E")"
    chk "$L H6 a failed external walk (xargs status 126) returns 2" eqv "$(val "$R/sim/rc")" 2
    chk "$L H6 the failed walk is logged" has "$R/roam.log" "WARN od_walk restorecon: walk FAILED (find status 0, xargs status 126)"
    chk "$L H6 a failed pair writes no reowned restored line" hasnot "$R/roam.log" "reowned restored"
    chk "$L H6 no count file is left in \$STATE (failed walk)" eqv "$(left)" ""
    mkroot; CE="$R/data/user/$UID_"; D="$CE/$PKG"; echo once > "$R/sim/mode.chown"; echo 1 > "$R/sim/findrc"
    run "$sh" "$(watched "$CE" "$D")"
    chk "$L H6 a failed CE chown walk (find status 1) returns 2" eqv "$(val "$R/sim/rc")" 2
    chk "$L H6 the failed chown walk is logged" has "$R/roam.log" "WARN od_walk chown: walk FAILED (find status 1, xargs status 0)"
    chk "$L H6 a failed chown walk skips the relabel" eqv "$(calls chcon)" ""
    chk "$L H6 a failed chown walk writes no reowned restored line" hasnot "$R/roam.log" "reowned restored"
    chk "$L H6 no count file is left in \$STATE (failed chown walk)" eqv "$(left)" ""
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
  # ENVIRON, not -v: -v processes escapes, and an anchor ending in a line-continuation backslash never matched under the
  # build box's gawk 5.2 (round 68), so the control and every mutant on such an anchor read as moved or inert.
  XF_FN="$1() {" XF_FR="$2" XF_TO="$3" awk '
    BEGIN { FN = ENVIRON["XF_FN"]; FR = ENVIRON["XF_FR"]; TO = ENVIRON["XF_TO"] }
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
  if [ "$by" = SURVIVE ]; then
    if [ "$mrc" = 0 ]; then echo "  ok    survived (no case reads it): $id $label"; else echo "  FAIL  CONTROL CONVICTED (a case reads what it changes): $id $label"; MF=$((MF+1)); fi
    return
  fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $by"*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED by $by under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted by $by: $id $label"; fi
}
L_RW='    od_walk none 3 chown -h "$target:$target" "$pkgdir" \'
L_RIF='  if [ -n "${OD_LABEL_COUNT:-}" ]; then'
L_EW='      od_walk prune 1 restorecon "$2" \'
L_BATCH=$(grep -m1 -F '    | xargs -0 -r -n 256 sh -c ' "$SUT")
L_ST='  if [ "$rc" = 0 ] && [ "$fs" = 0 ]; then return 0; fi'
L_RLOG='  if [ -z "${OD_OKDEFER:-}" ]; then echo "[roamd] relabelled $n restored entr(ies) of ${d##*/} to the app'\''s context (NWP-20261005-03)" >> "$LOG"; else OD_OKBUF="${OD_OKBUF:-}[roamd] relabelled $n restored entr(ies) of ${d##*/} to the app'\''s context (NWP-20261005-03)'
# The control: replacing a line with itself must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
if ! xform reown_restored "$L_RW" "$L_RW" > "$c" || ! cmp -s "$SUT" "$c"; then
  echo "  FAIL  the transform does not reproduce $SUT (the anchors moved)"; MF=$((MF+1))
fi
mutate X1 "the reown walk writes no count" "H1 at least 3 progress lines" reown_restored "$L_RW" \
  '    OD_LABEL_COUNT= od_walk none 3 chown -h "$target:$target" "$pkgdir" \'
mutate X2 "the reown is the plain chown -R always" "H1 at least 3 progress lines" reown_restored "$L_RIF" '  if false; then'
mutate X3 "the reown is counted even with no count file" "H4" reown_restored "$L_RIF" '  if :; then'
mutate X4 "the reown walk follows links (chown, not chown -h)" "H1 each chown call" reown_restored "$L_RW" \
  '    od_walk none 2 chown "$target:$target" "$pkgdir" \'
mutate X5 "the external volumes take the plain restorecon -R always" "H2 at least 3 progress lines" od_relabel "$L_EW" \
  '      { restorecon -R "$2" 2>>"$LOG"; : od_walk prune 1 restorecon "$2"; } \'
mutate X6 "the external walk writes no count" "H2 at least 3 progress lines" od_relabel "$L_EW" \
  '      OD_LABEL_COUNT= od_walk prune 1 restorecon "$2" \'
mutate X7 "the external walk keeps -R" "H2 each restorecon call" od_relabel "$L_EW" \
  '      od_walk prune 2 restorecon -R "$2" \'
mutate X8 "od_walk's batches write no count" "H1 at least 3 progress lines" od_walk "$L_BATCH" \
  "$(printf '%s\n' "$L_BATCH" | sed 's/ \[ -z "\${OD_LABEL_COUNT:-}" \] || echo "\$#" >> "\$OD_LABEL_COUNT";//')"
mutate X9 "od_walk ignores find's status (lynx S16: the walk answered OK)" "H6 a failed CE chown walk" od_walk "$L_ST" \
  '  if [ "$rc" = 0 ]; then return 0; fi'
mutate C "the relabelled line's undeferred wording (no case reads it)" SURVIVE relabel_restored "$L_RLOG" \
  "$(printf '%s\n' "$L_RLOG" | sed 's/the app'\''s context (NWP-20261005-03)" >> "\$LOG"/the app context (NWP-20261005-03)" >> "$LOG"/')"

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
