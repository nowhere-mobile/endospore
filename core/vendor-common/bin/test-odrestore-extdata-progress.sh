#!/usr/bin/env bash
# test-odrestore-extdata-progress.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's last hand-back step, the re-own
# and the -D relabel of the app's Android/data, feeds the daemon's stall clock (NWP-20261208-13).
#
# WHY THIS IS COMMITTED. Backlog row 'An app with a large data hold never gets its data back: its odrestore goes
# silent for 150 s after the copy, the daemon gives up and stops it, the hold is kept, and every retry copies the
# whole hold again'. The 2026-11-01 decision (h50 #1, docs/product-decisions.md) gives the label step the copy's rule:
# "The label step gets the same rule, counted in files labelled". The daemon resets its stall clock only when the
# progress line changes (core/agent main.go roamStallBudget, 150 s). NWP-20261207-05 counted reown_restored and
# od_relabel; the arm's last step, `reown_ext_appdata "$pkg"; restorecon -R -D <Android/data dir>`, still wrote no
# count, so an app with a large Android/data could be stopped there. Now the arm calls od_extdata_watched: the two
# chown walks of reown_ext_appdata and a `find -xdev` restorecon walk run as counted batches into one count file,
# watched as od_label_watched watches its own. Since NWP-20261209-04 each walk is od_walk's
# `find -print0 | xargs -0 -r -n 256 sh -c` (`find -exec sh -c` before it), and a failed walk makes the step 2.
#
# This suite EXECUTES the real extracted functions -- od_walk, reown_ext_appdata, od_extdata_watched, od_label_done,
# cutoff_prog and the ARM'S OWN LINES (from its od_extdata_watched call to the line before `_odt9=`) -- under every
# shell found (the device's is mksh). PATH stubs `find`, `xargs`, `chown`, `restorecon` and `stat` stand in for
# toybox; the xargs stub runs od_walk's REAL `sh -c` batch script over the batches of a counted walk. A wrapper over
# od_label_done counts the reads; a walk in mode grow releases batch k only after read
# k, and the wrapper returns only after that batch ended. So the batches move in lockstep with the reads:
#   X1 the Android/data chown walk grows: 3 batches after 3 reads -> at least 3 progress lines; each chown call is
#      `chown -h <uid*100000+appid>:ext_data_rw <2 names>`; the `reowned ext app-data` line once
#   X2 an obb dir: its walk runs `chown -h <id>:ext_obb_rw <2 names>`, after the data walk
#   X3 the restorecon walk grows: at least 3 progress lines; each call `restorecon -D <2 names>`, never -R; the
#      restorecon walk's find holds -xdev, each chown walk's find does not
#   X4 NO GROWTH: the restorecon walk runs for 3 reads with no batch -> no progress line (the 150 s stop still applies)
#   X5 PLAIN: OD_LABEL_COUNT unset or empty -> reown_ext_appdata runs one `chown -R` per present dir and no find; no
#      count file possible ($STATE empty) -> od_extdata_watched runs exactly the two chown -R, and its relabel walk,
#      with no find-status file to make, runs nothing and the step returns 2 (NWP-20261209-04)
#   X6 UNRESOLVABLE app id: no chown, no chown walk, no `reowned ext app-data` line; the restorecon walk still runs
#   X7 the count file holds digits only; no progress line or count line names the package or a path; nothing is left
#      in $STATE (the count file and od_walk's find-status files); the arm's step status is 0 on success
#   X8 FAILED WALK (NWP-20261209-04): the restorecon walk fails -> the arm's step status is 2 and its WARN line is
#      written, and the deferred `reowned ext app-data` line is not
#
#   bash test-odrestore-extdata-progress.sh              # the cases, under every shell found
#   bash test-odrestore-extdata-progress.sh --mutate     # ... plus mutants that must each CONVICT under each shell
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree, never copied.
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
ARM_NEXT='    _odt9=$(_ms 2>/dev/null)'

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
# arm_line <file>: inside the `  odrestore)` arm, the lines from the arm's own call (od_extdata_watched, or the plain
# reown_ext_appdata pair) to the line directly before ARM_NEXT: the call and its status handling (NWP-20261209-04)
arm_line() {
  awk -v n="$ARM_NEXT" '$0 == "  odrestore)" {f=1}
    f && /^    (od_extdata_watched|reown_ext_appdata) "\$pkg"/ {b=""; c=1}
    f && $0 == n {printf "%s", b; exit}
    c {b = b $0 "\n"}' "$1"
}
reroot() { printf '%s\n' "$1" | sed -E 's#([" |])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 PROG OW REA OLD EXW ARM n sh L R HARN="" D O want k
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
  never() { false; }
  clean() { [ -f "$1" ] && ! grep -qF -- "$PKG" "$1" && ! grep -qF / "$1"; }
  digits() { [ -s "$1" ] && ! grep -qv '^[0-9][0-9]*$' "$1"; }

  PROG=$(anchor_of "$f" 'cutoff_prog() {')
  OW=$(anchor_of "$f" 'od_walk() {')
  REA=$(anchor_of "$f" 'reown_ext_appdata() {')
  OLD=$(anchor_of "$f" 'od_label_done() {')
  EXW=$(anchor_of "$f" 'od_extdata_watched() {')
  ARM=$(arm_line "$f")
  # The shapes of NWP-20261209-04: every counted walk is an od_walk call.
  case "$PROG" in *'NOWHERE_PROGRESS.tmp'*'mv -f'*) ;; *) echo "EXTRACTION FAILED: cutoff_prog in $f" >&2; return 2 ;; esac
  case "$OW" in *'done < /proc/self/mountinfo'*'find "$root" "$@" -print0'*'xargs -0 -r -n 256 sh -c'*) ;; *) echo "EXTRACTION FAILED: od_walk in $f" >&2; return 2 ;; esac
  case "$REA" in *'/data/system/packages.list'*'return 1'*'od_walk '*'chown'*'chown -R "$target:ext_data_rw"'*'reowned ext app-data'*'return 0'*) ;; *) echo "EXTRACTION FAILED: reown_ext_appdata in $f" >&2; return 2 ;; esac
  case "$OLD" in *'done < "$1"'*) ;; *) echo "EXTRACTION FAILED: od_label_done in $f" >&2; return 2 ;; esac
  case "$ARM" in *reown_ext_appdata*'_odxf=$?'*|*od_extdata_watched*'_odxf=$?'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm's lines before _odt9 in $f" >&2; return 2 ;; esac
  # od_extdata_watched may be absent (the code before NWP-20261208-13): then nothing defines it, and X5 (c) FAILS.
  if [ -n "$EXW" ]; then
    case "$EXW" in *'od_walk '*'restorecon'*'od_label_done "$cnt"'*'cutoff_prog od'*) ;; *) echo "EXTRACTION FAILED: od_extdata_watched in $f" >&2; return 2 ;; esac
  fi
  # The wrapper below counts each read: the real reader is renamed, so a call to od_label_done goes through it.
  OLD=$(printf '%s\n' "$OLD" | sed '1s/^od_label_done() {$/od_label_done_real() {/')
  REA=$(reroot "$REA"); EXW=$(reroot "$EXW"); ARM=$(reroot "$ARM")
  # od_walk's prune reads the mount table: the case root's own (empty) one, so no host mount reaches a walk.
  OW=$(printf '%s\n' "$OW" | sed 's#done < /proc/self/mountinfo$#done < "$ROOT/sim/mountinfo"#')
  case "$OW" in *'done < "$ROOT/sim/mountinfo"'*) ;; *) echo "RE-ROOT FAILED: od_walk's mountinfo" >&2; return 2 ;; esac
  for n in "$OW" "$REA" "$EXW" "$ARM" "$OLD"; do
    [ "$(nleft "$n")" = 0 ] || { echo "RE-ROOT INCOMPLETE: an extracted part holds an absolute /data path" >&2; return 2; }
  done
  case "$REA" in *'$ROOT/data/system/packages.list'*'"$ROOT/data/media/$uid/Android/data/$pkg"'*) ;; *) echo "RE-ROOT FAILED: reown_ext_appdata" >&2; return 2 ;; esac

  mkroot() {
    local t
    R=$(mktemp -d -p "$W") || exit 2
    D="$R/data/media/$UID_/Android/data/$PKG"; O="$R/data/media/$UID_/Android/obb/$PKG"
    mkdir -p "$R/sim" "$R/bin" "$R/state" "$R/data/system" "$D"
    : > "$R/sim/reads"; : > "$R/sim/batches"; : > "$R/sim/calls"; : > "$R/sim/findargv"
    : > "$R/sim/mountinfo"; : > "$R/sim/walks"
    echo none > "$R/sim/mode.chown"; echo none > "$R/sim/mode.obb"; echo none > "$R/sim/mode.restorecon"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    printf '#!/bin/sh\necho u:object_r:media_rw_data_file:s0\n' > "$R/bin/stat"
    # chown, restorecon: each call is one line of sim/calls, its name and argv
    for t in chown restorecon; do
      printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$t" "$R/sim/calls" > "$R/bin/$t"
    done
    # find: records its argv (tab-joined) in sim/findargv and, for a -print0 walk (od_walk's), in sim/lastfind too,
    # then writes its root, NUL-terminated, for the xargs stub. It exits 0.
    cat > "$R/bin/find" <<EOF
#!/usr/bin/env bash
S="$R/sim"
{ for a in "\$@"; do printf '%s\t' "\$a"; done; echo; } >> "\$S/findargv"
d="\$1"; p0=0
for a in "\$@"; do case "\$a" in -print0) p0=1 ;; esac; done
[ "\$p0" = 1 ] || exit 0
{ for a in "\$@"; do printf '%s\t' "\$a"; done; echo; } > "\$S/lastfind"
printf '%s\0' "\$d"
exit 0
EOF
    # xargs: od_walk's `xargs -0 -r -n 256 sh -c SCRIPT od_walk K W1 W2 W3`; any other argv is recorded in sim/xargsbad
    # and fails. It reads the walk's root (the first NUL name) and drains the rest (so find has ended), then records
    # the walk in sim/walks: its words K W1 W2 W3, `|`, and its find argv, all tab-joined. The walk is named by its
    # tool and root: a chown walk of an obb dir is `obb`, any other chown walk `chown`, a restorecon walk
    # `restorecon`; its mode is sim/mode.<walk>: grow runs batch k (2 names) through the REAL batch script after read
    # k and records it in sim/batches, then waits for the read that sees the last batch; flat waits for 3 reads and
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
{ printf '%s\t' "\${cmd[@]:4}" "|"; cat "\$S/lastfind"; } >> "\$S/walks"
waitr() {
  local i=0
  while [ "\$(grep -c . "\$S/reads")" -lt "\$1" ]; do
    i=\$((i+1)); [ "\$i" -le 600 ] || { : > "\$S/timeout"; return 1; }
    sleep 0.1
  done
}
case "\${cmd[5]}" in chown) w=chown; case "\$d" in */Android/obb/*) w=obb ;; esac ;; restorecon) w=restorecon ;; *) w=other ;; esac
rc=0
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
    chmod +x "$R/bin/stat" "$R/bin/chown" "$R/bin/restorecon" "$R/bin/find" "$R/bin/xargs"
  }
  # driver <body>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf "ROOT='%s'\nLOG='%s'\nuid=%s\nPATH='%s':\"\$PATH\"\nexport PATH\n" "$R" "$R/roam.log" "$UID_" "$R/bin"
      printf "STATE='%s'\nNOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" "$R/state" "$R/prog"
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
      printf '%s\n' "$PROG" "$OW" "$REA" "$OLD" "$EXW"
      printf '%s\n' "$1"
    } > "$R/driver.sh"
  }
  run() {  # run <sh> <body>
    local e
    driver "$2"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  ticks() { local l; l=$(val "$R/prog"); case "$l" in "cutoff od "*) echo "${l#cutoff od }" ;; *) echo 0 ;; esac; }
  reads() { grep -c . "$R/sim/reads"; }
  left() { ls -A "$R/state" | tr '\n' ' '; }
  calls() { grep "^$1 " "$R/sim/calls"; }
  # argv_of <word>...: the sim/walks lines (od_walk words, then the find argv) of the walks whose tool words are these
  argv_of() { local pat; pat=$(printf '\t%s' "$@"); grep -F -- "$pat$(printf '\t')" "$R/sim/walks"; }
  allx() { local l; [ -n "$1" ] || return 1; while IFS= read -r l; do case "$l" in *"	-xdev	"*) ;; *) return 1 ;; esac; done <<< "$1"; }
  nonex() { local l; [ -n "$1" ] || return 1; while IFS= read -r l; do case "$l" in *-xdev*) return 1 ;; esac; done <<< "$1"; }
  ARMB="pkg='$PKG'
$ARM
echo \"\${_odxf-unset}\" > \"\$ROOT/sim/armrc\""
  RLOG="[roamd] reowned ext app-data $PKG -> $OWNED (user $UID_)"
  RLOGN() { grep -cF -- "$RLOG" "$R/roam.log" 2>/dev/null; }

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh X1: the Android/data chown walk, 3 batches, each after a read -> a progress line per growth =="
    mkroot; echo grow > "$R/sim/mode.chown"; : > "$R/sim/grow"
    run "$sh" "$ARMB"
    chk "$L X1 at least 3 progress lines" atleast "$(ticks)" 3
    chk "$L X1 the walks never hit their safety exit" absent "$R/sim/timeout"
    chk "$L X1 every walk is xargs -0 -r -n 256 sh -c <batch script> od_walk" absent "$R/sim/xargsbad"
    chk "$L X7 the arm's step status is 0 (X1)" eqv "$(val "$R/sim/armrc")" 0
    chk "$L X1 the 3 chown batches ran" eqv "$(grep -c . "$R/sim/batches")" 3
    want=""; for k in 1 2 3; do want="$want${want:+
}chown -h $OWNED:ext_data_rw $D/b${k}a $D/b${k}b"; done
    chk "$L X1 each chown call is chown -h <owner>:ext_data_rw <2 names>" eqv "$(calls chown)" "$want"
    chk "$L X1 the reowned ext app-data line is written once" eqv "$(RLOGN)" 1
    chk "$L X7 no count file is left in \$STATE (X1)" eqv "$(left)" ""
    chk "$L X7 the progress line names no package and no path (X1)" clean "$R/prog"
    chk "$L X7 the count file held digits only (X1)" digits "$R/sim/countseen"
    chk "$L X7 the count file names no package and no path (X1)" clean "$R/sim/countseen"

    say "== $sh X2: an obb dir -> its own walk with ext_obb_rw =="
    mkroot; mkdir -p "$O"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.obb"
    run "$sh" "$ARMB"
    chk "$L X2 the data walk then the obb walk, each chown -h with its group" eqv "$(calls chown)" \
      "chown -h $OWNED:ext_data_rw $D/o1a $D/o1b
chown -h $OWNED:ext_obb_rw $O/o1a $O/o1b"
    chk "$L X2 the reowned ext app-data line is written once" eqv "$(RLOGN)" 1
    chk "$L X7 no count file is left in \$STATE (X2)" eqv "$(left)" ""

    say "== $sh X3: the restorecon walk, 3 batches, each after a read -> a progress line per growth =="
    mkroot; mkdir -p "$O"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.obb"
    echo grow > "$R/sim/mode.restorecon"; : > "$R/sim/grow"
    run "$sh" "$ARMB"
    chk "$L X3 at least 3 progress lines" atleast "$(ticks)" 3
    chk "$L X3 the walks never hit their safety exit" absent "$R/sim/timeout"
    want=""; for k in 1 2 3; do want="$want${want:+
}restorecon -D $D/b${k}a $D/b${k}b"; done
    chk "$L X3 each restorecon call is restorecon -D <2 names>, never -R" eqv "$(calls restorecon)" "$want"
    chk "$L X3 the restorecon walk's find argv holds -xdev" allx "$(argv_of restorecon -D)"
    chk "$L X3 the chown walks' find argv (data and obb) hold no -xdev" nonex "$(argv_of chown -h)"
    chk "$L X3 there are two chown walks, data and obb" eqv "$(argv_of chown -h | grep -c .)" 2
    chk "$L X7 no count file is left in \$STATE (X3)" eqv "$(left)" ""
    chk "$L X7 the progress line names no package and no path (X3)" clean "$R/prog"
    chk "$L X7 the count file held digits only (X3)" digits "$R/sim/countseen"
    chk "$L X7 the count file names no package and no path (X3)" clean "$R/sim/countseen"

    say "== $sh X4: the restorecon walk runs for 3 reads with no batch -> no progress line =="
    mkroot; echo flat > "$R/sim/mode.restorecon"
    run "$sh" "$ARMB"
    chk "$L X4 no progress line" absent "$R/prog"
    chk "$L X4 the count was read at least 3 times" atleast "$(reads)" 3
    chk "$L X4 the walk never hit its safety exit" absent "$R/sim/timeout"
    chk "$L X7 no count file is left in \$STATE (X4)" eqv "$(left)" ""

    for n in unset empty; do
      say "== $sh X5 ($n): OD_LABEL_COUNT $n -> reown_ext_appdata runs the plain chown -R =="
      mkroot; mkdir -p "$O"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.obb"
      if [ "$n" = unset ]; then k='unset OD_LABEL_COUNT OD_LABEL_LOG'; else k='OD_LABEL_COUNT=; OD_LABEL_LOG=; export OD_LABEL_COUNT OD_LABEL_LOG'; fi
      run "$sh" "$k; reown_ext_appdata '$PKG'; echo \$? > \"\$ROOT/sim/rc\""
      chk "$L X5 ($n) reown_ext_appdata runs one chown -R per present dir" eqv "$(val "$R/sim/calls")" \
        "chown -R $OWNED:ext_data_rw $D
chown -R $OWNED:ext_obb_rw $O"
      chk "$L X5 ($n) reown_ext_appdata runs no find" eqv "$(val "$R/sim/findargv")" ""
      chk "$L X5 ($n) reown_ext_appdata returns 0" eqv "$(val "$R/sim/rc")" 0
      chk "$L X5 ($n) the reowned ext app-data line is written once" eqv "$(RLOGN)" 1
    done
    say "== $sh X5 (c): no count file can be made -> the pair uncounted, the relabel walk fails with 2 =="
    if [ -n "$EXW" ]; then
      mkroot; mkdir -p "$O"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.restorecon"
      run "$sh" "STATE=; od_extdata_watched '$PKG'; echo \$? > \"\$ROOT/sim/rc\""
      chk "$L X5 (c) the two chown -R, then no restorecon" eqv "$(val "$R/sim/calls")" \
        "chown -R $OWNED:ext_data_rw $D
chown -R $OWNED:ext_obb_rw $O"
      chk "$L X5 (c) no find" eqv "$(val "$R/sim/findargv")" ""
      chk "$L X5 (c) no progress line" absent "$R/prog"
      chk "$L X5 (c) the step returns 2" eqv "$(val "$R/sim/rc")" 2
      chk "$L X5 (c) the relabel walk logged that it has no status file" has "$R/roam.log" "WARN od_walk restorecon: no status file -- walk not run"
    else
      chk "$L X5 (c) od_extdata_watched exists" never
    fi

    say "== $sh X6: the app id is not resolvable -> no chown, the relabel still runs =="
    mkroot; mkdir -p "$O"; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.obb"; echo once > "$R/sim/mode.restorecon"
    echo "com.example.other 10999 0 /data/user/0/com.example.other default none 0 1 1234" > "$R/data/system/packages.list"
    run "$sh" "$ARMB"
    chk "$L X6 no chown ran" eqv "$(calls chown)" ""
    chk "$L X6 no chown walk ran" eqv "$(argv_of chown -h)" ""
    chk "$L X6 no reowned ext app-data line" hasnot "$R/roam.log" "reowned ext app-data"
    chk "$L X6 the restorecon walk still ran" eqv "$(calls restorecon)" "restorecon -D $D/o1a $D/o1b"
    chk "$L X7 no count file is left in \$STATE (X6)" eqv "$(left)" ""

    say "== $sh X8: the restorecon walk fails -> the step is 2, its WARN line, no reowned ext app-data line =="
    mkroot; echo once > "$R/sim/mode.chown"; echo once > "$R/sim/mode.restorecon"; echo 126 > "$R/sim/xargsrc.restorecon"
    run "$sh" "$ARMB"
    chk "$L X8 the arm's step status is 2" eqv "$(val "$R/sim/armrc")" 2
    chk "$L X8 the failed walk is logged" has "$R/roam.log" "WARN od_walk restorecon: walk FAILED (find status 0, xargs status 126)"
    chk "$L X8 the arm logs the failed hand-back" has "$R/roam.log" "WARN odrestore $PKG Android/data hand-back FAILED"
    chk "$L X8 the chown walk ran" eqv "$(calls chown)" "chown -h $OWNED:ext_data_rw $D/o1a $D/o1b"
    chk "$L X8 a failed step writes no reowned ext app-data line" hasnot "$R/roam.log" "reowned ext app-data"
    chk "$L X7 no count file is left in \$STATE (X8)" eqv "$(left)" ""
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
# xform <fn> <from> <to>: inside function <fn> only, the line exactly <from> becomes <to>; <fn> "-" is the whole file.
xform() {
  awk -v FN="$1() {" -v ALL="$([ "$1" = - ] && echo 1 || echo 0)" -v FR="$2" -v TO="$3" '
    $0 == FN { fn = 1 }
    (fn || ALL) && $0 == FR { hit = 1; print TO; next }
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
L_DW='    if [ -d "/data/media/$uid/Android/data/$pkg" ]; then od_walk none 3 chown -h "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" || appid=failed; fi'
L_IF='  if [ -n "${OD_LABEL_COUNT:-}" ]; then'
L_RW='      if [ -d "$d" ]; then od_walk prune 2 restorecon -D "$d" -xdev || r=2; fi'
L_ARM='    od_extdata_watched "$pkg"'
L_GROW='    if [ "$cur" -gt "$last" ]; then cutoff_prog od; last=$cur; fi'
L_CMT='  # Exact on field 1 (NWP-20261111-11): the grep this replaced read $pkg as a regex, so a look-alike name took the data.'
# The control: replacing a line with itself must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
if ! xform reown_ext_appdata "$L_DW" "$L_DW" > "$c" || ! cmp -s "$SUT" "$c"; then
  echo "  FAIL  the transform does not reproduce $SUT (the anchors moved)"; MF=$((MF+1))
fi
mutate M1 "the data walk writes no count" "X1 at least 3 progress lines" reown_ext_appdata "$L_DW" \
  '    if [ -d "/data/media/$uid/Android/data/$pkg" ]; then OD_LABEL_COUNT= od_walk none 3 chown -h "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" || appid=failed; fi'
mutate M2 "the re-own is the plain chown -R always" "X1 at least 3 progress lines" reown_ext_appdata "$L_IF" '  if false; then'
mutate M3 "the re-own is counted even with no count file" "X5" reown_ext_appdata "$L_IF" '  if :; then'
mutate M4 "the data walk follows links (chown, not chown -h)" "X1 each chown call" reown_ext_appdata "$L_DW" \
  '    if [ -d "/data/media/$uid/Android/data/$pkg" ]; then od_walk none 2 chown "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" || appid=failed; fi'
mutate M5 "the restorecon walk keeps -R" "X3 each restorecon call" od_extdata_watched "$L_RW" \
  '      if [ -d "$d" ]; then od_walk prune 3 restorecon -R -D "$d" -xdev || r=2; fi'
mutate M6 "the restorecon walk drops -D" "X3 each restorecon call" od_extdata_watched "$L_RW" \
  '      if [ -d "$d" ]; then od_walk prune 1 restorecon "$d" -xdev || r=2; fi'
mutate M7 "the arm keeps the plain pair" "X1 at least 3 progress lines" - "$L_ARM" \
  '    reown_ext_appdata "$pkg"; restorecon -R -D "/data/media/$uid/Android/data/$pkg" 2>>"$LOG"'
mutate M8 "a progress line on every poll, growth or not" "X4 no progress line" od_extdata_watched "$L_GROW" \
  '    cutoff_prog od; last=$cur'
mutate M9 "the restorecon walk drops -xdev" "X3 the restorecon walk's find argv holds -xdev" od_extdata_watched "$L_RW" \
  '      if [ -d "$d" ]; then od_walk prune 2 restorecon -D "$d" || r=2; fi'
mutate M10 "the data chown walk gains -xdev" "X3 the chown walks' find argv" reown_ext_appdata "$L_DW" \
  '    if [ -d "/data/media/$uid/Android/data/$pkg" ]; then od_walk none 3 chown -h "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" -xdev || appid=failed; fi'
mutate M11 "a failed relabel walk does not fail the step" "X8 the arm's step status is 2" od_extdata_watched "$L_RW" \
  '      if [ -d "$d" ]; then od_walk prune 2 restorecon -D "$d" -xdev || :; fi'
mutate C "a body comment's wording (no case reads it)" SURVIVE reown_ext_appdata "$L_CMT" \
  '  # Exact on field 1 (NWP-20261111-11): the grep this replaced read the package as a regex, so a look-alike took the data.'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
