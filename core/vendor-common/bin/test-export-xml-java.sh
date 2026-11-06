#!/usr/bin/env bash
# test-export-xml-java.sh [--mutate] -- the export's XML attribute escaper, run under javac (NWP-20261109-25).
#
# WHY THIS IS COMMITTED. ProfileActivity writes every SMS address and body and every call number into messages.xml /
# calls.xml through an attribute escaper. The old one let a control character (ESC, NUL), U+FFFE/U+FFFF or an unpaired
# surrogate through raw -- XML 1.0 forbids them, so one such text made the whole file unparseable -- and wrote a tab
# raw, which a parser reads back as a space. The escaper now lives in ExportXml.java (pure java.lang);
# core/chooser/tests/export-xml/run.sh compiles and runs it against ExportXmlCases, which also parses every case with a
# conforming parser. The PINS check the wiring cases cannot see: ProfileActivity has no xmlAttr left and buildSmsXml
# (address, body) and buildCallLogXml (number) all go through ExportXml.attr.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-export-xml-java.sh            # the cases and the pins
#   bash test-export-xml-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
ESC="$root/core/chooser/src/com/nowhere/chooser/ExportXml.java"
RUN="$root/core/chooser/tests/export-xml/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its mutants" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# count <text> <needle> -> how many times needle occurs
count() { local t="${1//"$2"/$'\x01'}" r; r="${t//[^$'\x01']/}"; echo "${#r}"; }

# pins <ProfileActivity.java> -> 0 all hold, 1 one failed
pins() {
  local f="$1" b
  [[ "$(cat "$f")" != *'xmlAttr('* ]] || { echo "  PIN P1 ProfileActivity still holds xmlAttr(" >&2; return 1; }
  b=$(body "$f" 'private byte[] buildSmsXml(')
  [ -n "$b" ] || { echo "  PIN P2 buildSmsXml not found" >&2; return 1; }
  [ "$(count "$b" 'ExportXml.attr(iA >= 0 ? c.getString(iA)')" = 1 ] || { echo "  PIN P2 the sms address is not escaped through ExportXml.attr" >&2; return 1; }
  [ "$(count "$b" 'ExportXml.attr(iB >= 0 ? c.getString(iB)')" = 1 ] || { echo "  PIN P3 the sms body is not escaped through ExportXml.attr" >&2; return 1; }
  b=$(body "$f" 'private byte[] buildCallLogXml(')
  [ "$(count "$b" 'ExportXml.attr(c.getString(0))')" = 1 ] || { echo "  PIN P4 the call number is not escaped through ExportXml.attr" >&2; return 1; }
  return 0
}

# suite <ProfileActivity.java> <ExportXml.java> -> 0 pass, 1 a case or a pin failed, 2 missing source, 3 did not compile.
suite() {
  pins "$1" || return 1
  bash "$RUN" "$2" "$W"
}

echo "== $SRC"
suite "$SRC" "$ESC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: esc|activity> <perl-expr>
mut() {
  local d m rc a p src; d=$(mktemp -d -p "$W"); a="$SRC"; p="$ESC"
  if [ "$2" = esc ]; then m="$d/ExportXml.java"; p="$m"; src="$ESC"; else m="$d/ProfileActivity.java"; a="$m"; src="$SRC"; fi
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$p" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "E1 the tab rule removed"                esc      's/\n\s*case .\\t.: b\.append\("&#9;"\); break;//' || fails=$((fails+1))
mut "E2 forbidden code points kept raw"      esc      's/if \(ok\) b\.appendCodePoint\(cp\); else b\.append\(\(char\) 0xFFFD\);/b.appendCodePoint(cp);/' || fails=$((fails+1))
mut "E3 an unpaired surrogate passed through" esc     's/(int cp = s\.codePointAt\(i\);\n\s*i \+= Character\.charCount\(cp\);)/$1\n            if (cp >= 0xD800 \&\& cp <= 0xDFFF) { b.append((char) cp); continue; }/' || fails=$((fails+1))
mut "E4 a valid surrogate pair replaced"     esc      's/\(cp >= 0x10000 && cp <= 0x10FFFF\)/false/' || fails=$((fails+1))
mut "E5 the CRLF pair written as two"        esc      's/if \(i < n && s\.charAt\(i\) == .\\n.\) i\+\+;//' || fails=$((fails+1))
mut "E6 the sms body escaped with a raw value" activity 's/ExportXml\.attr\((iB >= 0 \? c\.getString\(iB\) : ""\))/($1)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
