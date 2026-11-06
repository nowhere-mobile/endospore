#!/usr/bin/env bash
# run.sh <StoreScreenCopy.java> <ChooserActivity.java> -- NWP-20261113-21: compile StoreScreenCopy directly (pure Java,
# no android.*) with StoreScreenCopyCases and run it, then pin that the Store settings screen's GET-STORE thread renders
# its message from StoreScreenCopy with GET-STORE's managed= line and holds neither old literal itself. NWP-20261124-16
# (decision #15): pin that the same thread hides the S3 fields, the secret's reveal wrapper, Save store and Test
# connection and sets the managed subtitle when StoreScreenCopy.showS3Fields(managed) is false, and that the initial
# build still shows every field. $JAVAC / $JAVA default to PATH; core/vendor-common/bin/test-store-screen-copy-java.sh is the CI entry point and finds them.
# Exit codes: 1 = a case or a pin failed; 2 = the store screen did not extract; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/StoreScreenCopy.java path/to/ChooserActivity.java}"
ACT="${2:?usage: run.sh path/to/StoreScreenCopy.java path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)  # the suite calls this with TMPDIR inside its own root
trap 'rm -rf "$D"' EXIT

# The store screen, from its declaration to the brace that closes it.
body=$(awk '
  !on && index($0, "private View buildStoreScreen() {") { on=1; depth=0 }
  on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
' "$ACT")
[ -n "$body" ] || { echo "EXTRACTION FAILED: the store screen is missing from $ACT" >&2; exit 2; }
pin=0
for want in 'final boolean managed = "yes".equals(m.get("managed"));' \
            'StoreScreenCopy.message(configured, managed, keyset)' \
            'StoreScreenCopy.isError(managed, keyset)'; do
  case "$body" in *"$want"*) ;; *) echo "  FAIL  pin: the store screen does not hold: $want"; pin=1 ;; esac
done
for lit in 'no store yet' 'a key is already set'; do
  case "$body" in *"$lit"*) echo "  FAIL  pin: the store screen still holds the literal \"$lit\""; pin=1 ;; esac
done

# NWP-20261124-16: the hide block in the GET-STORE thread, from its if to the brace that closes it. A missing block is a
# pin failure (exit 1), so a mutant that removes it is convicted.
hide_if='if (!StoreScreenCopy.showS3Fields(managed)) {'
cnt() { local n; n=$(grep -cF -- "$2" <<<"$1") || true; echo "${n:-0}"; }
[ "$(cnt "$body" "$hide_if")" -eq 1 ] || { echo "  FAIL  pin: the store screen does not hold exactly one: $hide_if"; pin=1; }
hide=$(awk -v w="$hide_if" '
  !on && index($0, w) { on=1; depth=0 }
  on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
' <<<"$body")
for want in 'endpointF.setVisibility(View.GONE);' 'bucketF.setVisibility(View.GONE);' 'regionF.setVisibility(View.GONE);' \
            'keyF.setVisibility(View.GONE);' '((View) secretF.getParent()).setVisibility(View.GONE);' \
            'save.setVisibility(View.GONE);' 'test.setVisibility(View.GONE);' \
            'sub.setText(StoreScreenCopy.subtitle(managed));'; do
  case "$hide" in *"$want"*) ;; *) echo "  FAIL  pin: the managed hide block does not hold: $want"; pin=1 ;; esac
done
case "$hide" in *' secretF.setVisibility('*) echo "  FAIL  pin: the hide block hides the bare secret field, not its reveal wrapper"; pin=1 ;; esac
# The block sits in the GET-STORE reader, after managed= is read, not in the initial build.
mline=$(grep -nF 'final boolean managed = "yes".equals(m.get("managed"));' <<<"$body" | head -n1 | cut -d: -f1) || true
hline=$(grep -nF -- "$hide_if" <<<"$body" | head -n1 | cut -d: -f1) || true
if [ -z "$mline" ] || [ -z "$hline" ] || [ "$hline" -le "$mline" ]; then
  echo "  FAIL  pin: the hide block is not in the GET-STORE reader after managed= is read"; pin=1
fi
# The initial build is unchanged: the self-hosted subtitle, the secret's wrapper, and each view hidden only in the block.
for want in 'final TextView sub = new TextView(this);' 'sub.setText(StoreScreenCopy.subtitle(false));' \
            'll.addView(PassReveal.wrap(secretF, MUTED), fieldLp(dp(20)));'; do
  case "$body" in *"$want"*) ;; *) echo "  FAIL  pin: the store screen's initial build does not hold: $want"; pin=1 ;; esac
done
for v in endpointF bucketF regionF keyF save test; do
  [ "$(cnt "$body" "$v.setVisibility(View.GONE);")" -eq 1 ] \
    || { echo "  FAIL  pin: $v.setVisibility(View.GONE) is not set exactly once (in the hide block)"; pin=1; }
done
case "$body" in *'S3-compatible'*) echo "  FAIL  pin: the store screen still holds the S3 subtitle literal"; pin=1 ;; esac

mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/StoreScreenCopy.java"
# The cases live in the default package, so they reach the package-private StoreScreenCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/StoreScreenCopyCases.java" > "$D/com/nowhere/chooser/StoreScreenCopyCases.java"
"$JAVAC" -encoding UTF-8 -d "$D/out" "$D/com/nowhere/chooser/StoreScreenCopy.java" \
  "$D/com/nowhere/chooser/StoreScreenCopyCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.StoreScreenCopyCases || rc=1
[ "$pin" -eq 0 ] && [ "$rc" -eq 0 ] || exit 1
