#!/usr/bin/env bash
# Endospore OS-level source patch (#148): make the SMS/MMS telephony providers PER-USER.
#
# Stock AOSP marks the sms / sms-changes / mms / mms-sms providers android:singleUser="true" -> a single
# instance in user 0 backed by ONE mmssms.db under /data/user/0. That is wrong for an amnesiac roaming OS:
# a roamed user's messages must live in ITS OWN CE database so they seal + wipe WITH the session and never
# leak across profiles. Dropping singleUser gives each user its own provider instance + its own CE
# mmssms.db (getInstanceForCe), which is where the gate's TelIngest injects the sealed/live rows (#149) and
# where the roamed Messaging reads + displays them.
#
# ONLY the four message providers change. The other providers (telephony, carrier_information,
# hbpcd_lookup, carrier_id, satellite) are genuinely global config tables and KEEP singleUser.
#
# Idempotent (a second run finds no singleUser to remove in those four blocks). Run after a fresh
# TelephonyProvider checkout, before `m`.
# Usage: telephony-per-user.sh <graphene-tree-root>
#
# Exit codes (NWP-20261021-05): 0 applied or already current, 1 no manifest, 2 DRIFT. The sed edits a temp copy made
# beside the manifest; the manifest is replaced only when each of the four class names still appears exactly once,
# none of their opening tags carries singleUser, and the overall singleUser count dropped by exactly the number held
# in those four tags. Otherwise `DRIFT:` on stderr, exit 2, manifest untouched. editions/diaspore/build/
# test-patch-endstate.sh pins both copies.
set -euo pipefail
TREE="${1:?usage: telephony-per-user.sh <graphene-tree-root>}"
M="$TREE/packages/providers/TelephonyProvider/AndroidManifest.xml"
[ -f "$M" ] || { echo "no TelephonyProvider AndroidManifest.xml at $M" >&2; exit 1; }

CLASSES="SmsProvider SmsChangesProvider MmsProvider MmsSmsProvider"
TMPS=()
cleanup(){ local t; for t in ${TMPS[@]+"${TMPS[@]}"}; do rm -f "$t"; done; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

# occ <file> <literal>: how many times the literal occurs in the file (awk reads to the end; no grep -q).
occ(){ awk -v p="$2" '{ s=$0; while ((i=index(s,p)) > 0) { n++; s=substr(s,i+length(p)) } } END { print n+0 }' "$1"; }
# su_in_tag <file> <cls>: singleUser occurrences inside the <provider ...> opening tag(s) whose text holds the
# class name. A tag runs from "<provider" to the first ">" after it, across lines, so a tag written on ONE line is
# read correctly (the sed range below is not).
su_in_tag(){
  awk -v cls="android:name=\"$2\"" -v p='android:singleUser="true"' '
    { line=$0
      if (!intag) { i=index(line,"<provider"); if (!i) next; line=substr(line,i); intag=1; text="" }
      j=index(line,">")
      if (j) {
        text=text substr(line,1,j); intag=0
        if (index(text,cls)) { s=text; while ((k=index(s,p)) > 0) { n++; s=substr(s,k+length(p)) } }
      } else text=text line "\n"
    }
    END { print n+0 }' "$1"
}

SU='android:singleUser="true"'
before=$(occ "$M" "$SU")
intag=0
for cls in $CLASSES; do n=$(su_in_tag "$M" "$cls"); intag=$((intag + n)); done

# Edit a temp copy made beside the manifest; the manifest itself is not touched until the copy checks out.
T=$(mktemp "$(dirname "$M")/.AndroidManifest.xml.nowhere.XXXXXX"); TMPS+=("$T"); cp -p "$M" "$T"

# For each of the four message-provider classes, delete the singleUser line within its <provider ...> opening
# tag (range: the class-name line to the first line closing the tag with '>'). The class name is quote-
# anchored so "SmsProvider" never matches "MmsSmsProvider" and "SmsProvider" never matches "SmsChangesProvider".
for cls in SmsProvider SmsChangesProvider MmsProvider MmsSmsProvider; do
  sed -i "/android:name=\"$cls\"/,/>/{/android:singleUser=\"true\"/d;}" "$T"
done
# edited:tpu

# The range delete is only right on the stock multi-line tags: it deletes a whole tag line written on one line, and
# on a tag that ends on its own line it runs on to the NEXT line holding ">". Check the copy, not the sed's exit.
bad=""
for cls in $CLASSES; do [ "$(occ "$T" "android:name=\"$cls\"")" = 1 ] || bad="$bad $cls"; done
[ -z "$bad" ] || { echo "[telephony-per-user] DRIFT: android:name=\"<class>\" is not present exactly once after the edit for:$bad" >&2; exit 2; }  # assert:tpu-names
bad=""
for cls in $CLASSES; do [ "$(su_in_tag "$T" "$cls")" = 0 ] || bad="$bad $cls"; done
[ -z "$bad" ] || { echo "[telephony-per-user] DRIFT: the opening tag of$bad still carries android:singleUser=\"true\"" >&2; exit 2; }  # assert:tpu-tags
after=$(occ "$T" "$SU")
[ "$after" = $((before - intag)) ] || { echo "[telephony-per-user] DRIFT: singleUser count went $before -> $after, expected $((before - intag)) (the four classes' tags held $intag): another provider lost one, or a tag line was deleted" >&2; exit 2; }  # assert:tpu-drop

cmp -s "$T" "$M" || cat "$T" > "$M"  # replace:tpu
rm -f "$T"

kept=$(occ "$M" "$SU")
echo "[telephony-per-user] SMS/MMS providers are per-user; $kept singleUser provider(s) kept (expect 5: telephony, carrier_information, hbpcd_lookup, carrier_id, satellite)"
