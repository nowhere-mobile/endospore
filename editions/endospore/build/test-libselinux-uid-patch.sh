#!/usr/bin/env bash
# test-libselinux-uid-patch.sh [--mutate] -- NWP-20261026-16.
#
# WHY THIS IS COMMITTED. libselinux-pkgdir-uid-aliasing.sh is applied to every Endospore build (build-device.sh's
# patches/*.sh glob) and no suite ran it. Until this slice it also removed the in-place `info->uid += ...` and exited 0
# when it redirected NO read site, which leaves every reader with the cached appid and no user offset: a secondary
# user's package dirs get user 0's MCS categories on every `restorecon -D`, the crash class the patch exists to prevent.
# These checks run the script against a synthetic android_device.c built from its own anchor text with context:
#   (a) pristine -> exit 0, the mutation gone, the local assigned from info->uid + the offset, the declaration inside
#       pkgdir_selabel_lookup() (not the decoy in package_info_init()), both read sites redirected, the output says 2;
#   (b) a re-run -> exit 0, `already applied`, the file byte-identical;
#   (c) ZERO read sites -> exit 1 and the file byte-identical;
#   (d) no mutating statement / no signature / no declaration after the signature / the declaration after the mutation
#       -> exit 1 and the file byte-identical;
#   (e) a missing target file -> exit 1.
# They cannot show that the anchors still match the real GrapheneOS tree; the build host checks that.
# Needs python3, as the patch does.
#
#   bash test-libselinux-uid-patch.sh            # the invariants
#   bash test-libselinux-uid-patch.sh --mutate   # ... plus mutations of the script that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
python3 --version
HERE="$(cd "$(dirname "$0")" && pwd)"
S0="$HERE/patches/libselinux-pkgdir-uid-aliasing.sh"
REL=external/selinux/libselinux/src/android/android_device.c
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# tree <dir> pristine|noreads|nomutate|nosig|nodecl|declafter
tree(){
  local f="$1/$REL" v="$2" sig decl mut r1 r2
  mkdir -p "$(dirname "$f")"
  sig='static int pkgdir_selabel_lookup(const char *pathname, const char *seinfo, uid_t uid, char **secontextp)'
  decl=$'\tstruct pkg_info *info = NULL;'
  mut=$'\t\tinfo->uid += userid_from_path * AID_USER_OFFSET;'
  r1=$'\trc = seapp_context_lookup(SEAPP_DOMAIN, info ? info->uid : uid, 0, seinfo, pkgname, ctx);'
  r2=$'\trc = seapp_context_lookup(SEAPP_TYPE, info ? info->uid : uid, 0, seinfo, pkgname, ctx2);'
  case "$v" in
    nosig) sig=${sig/pkgdir_selabel_lookup/pkgdir_lookup} ;;
    nomutate) mut=$'\t\tuid_t u = info->uid;' ;;
    noreads)
      r1=$'\trc = info ? seapp_context_lookup(SEAPP_DOMAIN, info->uid, 0, seinfo, pkgname, ctx) : 0;'
      r2=$'\trc = seapp_context_lookup(SEAPP_TYPE, info->uid, 0, seinfo, pkgname, ctx2);' ;;
  esac
  {
    echo '#include <selinux/android.h>'; echo
    echo 'static struct pkg_info *package_info_init(void)'; echo '{'
    echo "$decl"; printf '\treturn info;\n}\n\n'
    echo "$sig"; echo '{'
    echo $'\tchar *pkgname = NULL;'
    [ "$v" = nodecl ] || [ "$v" = declafter ] || echo "$decl"
    echo $'\tunsigned long userid_from_path = 0;'
    echo $'\tchar *ctx = NULL, *ctx2 = NULL;'
    echo $'\tint rc;'
    echo $'\tif (!seinfo) {'
    echo $'\t\tinfo = package_info_lookup(pkgname);'
    echo $'\t\tif (!info) goto err;'
    echo "$mut"
    [ "$v" = declafter ] && echo "$decl"
    echo $'\t}'
    echo "$r1"; echo "$r2"
    echo $'\treturn rc;'
    echo $'err:'
    echo $'\treturn -1;'
    echo '}'
  } > "$f"
}

# checks: every case against the script in $S, one "  ok (x) ..." / "  FAIL (x) ..." line each.
checks(){
  local t o rc v before
  ok(){ echo "  ok $1"; }
  bad(){ echo "  FAIL $1"; }
  t=$(mktemp -d -p "$W"); tree "$t" pristine; F="$t/$REL"
  o=$(bash "$S" "$t" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "(a) pristine exits 0" || bad "(a) pristine exits $rc"
  [ "$(grep -cP '\t\tinfo->uid \+= userid_from_path' "$F")" = 0 ] && ok "(a) mutation gone" || bad "(a) mutation still present"
  grep -qF $'\t\tnowhere_resolved_uid = info->uid + userid_from_path * AID_USER_OFFSET;' "$F" \
    && ok "(a) local assigned from info->uid + offset" || bad "(a) local not assigned from info->uid + offset"
  [ "$(grep -cF 'info ? info->uid : uid' "$F")" = 0 ] && ok "(a) no unredirected read" || bad "(a) unredirected read left"
  [ "$(grep -c 'seapp_context_lookup(SEAPP_[A-Z]*, nowhere_resolved_uid,' "$F")" = 2 ] \
    && ok "(a) both read sites redirected" || bad "(a) read sites not both redirected"
  [ "$(grep -cF 'uid_t nowhere_resolved_uid = uid;' "$F")" = 1 ] \
    && [ "$(grep -n 'uid_t nowhere_resolved_uid = uid;' "$F" | cut -d: -f1)" -gt "$(grep -n 'static int pkgdir_selabel_lookup(' "$F" | cut -d: -f1)" ] \
    && ok "(a) declared once, inside pkgdir_selabel_lookup" || bad "(a) declaration misplaced"
  case "$o" in *"2 read site(s) redirected"*) ok "(a) output names 2 sites" ;; *) bad "(a) output: $o" ;; esac
  cp "$F" "$W/after-a"
  o=$(bash "$S" "$t" 2>&1); rc=$?
  [ "$rc" = 0 ] && cmp -s "$F" "$W/after-a" && ok "(b) re-run exits 0, file identical" || bad "(b) re-run exit $rc or file changed"
  case "$o" in *"already applied"*) ok "(b) says already applied" ;; *) bad "(b) output: $o" ;; esac
  for v in noreads nomutate nosig nodecl declafter; do
    t=$(mktemp -d -p "$W"); tree "$t" "$v"; F="$t/$REL"; cp "$F" "$W/before"
    o=$(bash "$S" "$t" 2>&1); rc=$?
    local c=d; [ "$v" = noreads ] && c=c
    [ "$rc" = 1 ] && ok "($c) $v exits 1" || bad "($c) $v exits $rc"
    cmp -s "$F" "$W/before" && ok "($c) $v leaves the file byte-identical" || bad "($c) $v rewrote the file"
    [ "$v" = noreads ] && { case "$o" in *"no 'info ? info->uid : uid' read site found"*) ok "(c) names the missing read site" ;; *) bad "(c) output: $o" ;; esac; }
  done
  t=$(mktemp -d -p "$W")
  o=$(bash "$S" "$t" 2>&1); rc=$?
  [ "$rc" = 1 ] && ok "(e) missing target exits 1" || bad "(e) missing target exits $rc"
}

run_checks(){ OUT=$(checks); echo "$OUT"; NFAIL=$(grep -c '^  FAIL' <<<"$OUT"); NOK=$(grep -c '^  ok' <<<"$OUT"); }

S="$S0"
echo "== the patch script"
run_checks
echo "== $NOK passed, $NFAIL failed"
[ "$NFAIL" = 0 ] || exit 1

[ "$MUTATE" = yes ] || exit 0
LOST=0; N=0
# mutant <label> <case-letter> <old> <new>
mutant(){
  local label="$1" c="$2" old="$3" new="$4" m
  N=$((N+1)); m="$W/mut-$N.sh"
  if ! python3 - "$S0" "$m" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
t = s.replace(old, new, 1)
if t == s:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(t)
PY
  then echo "  FAIL mutant did not apply: $label"; LOST=$((LOST+1)); return; fi
  S="$m"; run_checks >/dev/null
  if grep -q "^  FAIL ($c)" <<<"$OUT"; then echo "  ok convicted: $label by ($c)"
  else echo "  FAIL not convicted by ($c): $label"; LOST=$((LOST+1)); fi
}
echo "== mutants"
mutant "L1 zero-site refusal removed" c "if n == 0:" "if False:"
mutant "L2 idempotence marker check removed" b "if 'nowhere_resolved_uid' in s:" "if False:"
mutant "L3 declaration-before-mutation check removed" d "if decl_at > s.find(mutate):" "if False:"
mutant "L4 read-site replace dropped, count kept" a 's = s.replace("info ? info->uid : uid", "nowhere_resolved_uid")' "pass"
[ "$LOST" = 0 ] && echo "== every mutant convicted" || { echo "== $LOST mutant(s) not convicted"; exit 1; }
