#!/usr/bin/env bash
# carrierconfig2-sms-to-mms.sh -- CarrierConfig2 turns a long text into an MMS for every carrier (NWP-20261130-15).
#
# WHY. AOSP Messaging sent a 19-part text as one multipart SMS. It timed out before the radio and never went out
# (lynx 2026110402, read over USB on 2026-11-06). The two carrier-config keys that turn a long text into an MMS are
# smsToMmsTextThreshold and smsToMmsTextLengthThreshold (CarrierConfigManager KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT /
# KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT). The platform default of both is -1 (never convert), and no
# CarrierSettings entry sets them. GrapheneOS binds app.grapheneos.carrierconfig2, which builds its bundle in Java from
# the CarrierSettings protobuf files, so no runtime overlay can set the keys (NOWHERE-1689). Decision:
# docs/product-decisions.md, 2026-11-06, "long texts become MMS through a CarrierConfig2 patch".
#
# WHAT. One file: packages/apps/CarrierConfig2/src/app/grapheneos/carrierconfig2/CarrierServiceImpl.java.
# onLoadConfig(int subId, CarrierIdentifier) is the one OS entry point. Its last line returns the loader's bundle; the
# patch wraps that return in nowhereSmsToMms(), a helper inserted after the class line. The helper fills each key that
# the bundle does not hold. It keeps every value the carrier supplies, 0 and -1 included: an explicit 0 or -1 is that
# carrier's choice to never convert, and the carrier knows its own MMSC and SMSC limits. A null bundle from load() (no
# default CarrierSettings file) becomes a bundle with the two keys.
# Values: 7 parts (the decision) and 1071 characters (7 x 153 GSM-7 characters per concatenated part).
# Residual: when CSettingsDir.getDefault() is null the method still returns null, as stock (an image fault).
#
# Lands in CarrierConfig2.apk (/system_ext/priv-app) -> `m`, system_ext reflash. To verify a build carries it: the
# APK's classes*.dex holds the literal `nowhere: sms-to-mms thresholds (NWP-20261130-15)` (patch-markers.tsv, checked
# by build-device.sh before signing); on a device `dumpsys carrier_config` shows smsToMmsTextThreshold = 7 and
# smsToMmsTextLengthThreshold = 1071, and logcat shows
#   CarrierServiceImpl: nowhere: sms-to-mms thresholds (NWP-20261130-15): parts set 7, length set 1071
# at each carrier-config load.
#
# Exit 0: patched now, or already carries this PATCH_VERSION. Exit 1: usage, or the file is missing.
# Exit 2: an anchor is missing, found twice, or outside onLoadConfig(int, ...); nothing is written.
# Exit 3: the file carries an OLDER copy of this patch. Every edit is a replace against PRISTINE anchors, so the
# script cannot re-apply over it; skipping would ship a build WITHOUT the newer patch. Revert first:
#   git -C <tree>/packages/apps/CarrierConfig2 checkout -- src/app/grapheneos/carrierconfig2/CarrierServiceImpl.java
# See docs/framework-patches.md.
set -euo pipefail
T="${1:?usage: carrierconfig2-sms-to-mms.sh <graphene-tree>}"
CC2="$T/packages/apps/CarrierConfig2"
REL=src/app/grapheneos/carrierconfig2/CarrierServiceImpl.java
F="$CC2/$REL"
PATCH_VERSION=2
[ -f "$F" ] || { echo "[carrierconfig2-sms-to-mms] MISSING $F" >&2; exit 1; }

python3 - "$F" "$PATCH_VERSION" "$CC2" "$REL" <<'PY'
import sys
p, ver, cc2, rel = sys.argv[1:5]
TAG = '[carrierconfig2-sms-to-mms]'
FAMILY = 'nowhere-cc2-sms-to-mms PATCH_VERSION'
STAMP = FAMILY + ' ' + ver + ' (NWP-20261130-15)'
REVERT = '    git -C "%s" checkout -- %s' % (cc2, rel)
s = open(p, encoding='utf-8', newline='').read()

def die(code, msg):
    print('%s %s' % (TAG, msg), file=sys.stderr)
    sys.exit(code)

if STAMP in s:
    print('%s already patched (PATCH_VERSION %s) -- skipped: %s' % (TAG, ver, p)); sys.exit(0)
if FAMILY in s:
    print('%s ERROR: %s carries an OLDER carrierconfig2-sms-to-mms patch (not PATCH_VERSION %s).' % (TAG, p, ver),
          file=sys.stderr)
    print('Revert it, then re-run this script:', file=sys.stderr)
    print(REVERT, file=sys.stderr)
    print('Refusing to skip: skipping would ship a build WITHOUT the newer patch.', file=sys.stderr)
    sys.exit(3)

ANCHOR_A = 'public class CarrierServiceImpl extends CarrierService {\n'
ANCHOR_B = '        return new CarrierConfigLoader(ctx, csd).load(carrierIdExt);\n'
WRAPPED = '        return nowhereSmsToMms(new CarrierConfigLoader(ctx, csd).load(carrierIdExt));\n'
SIG = '    public PersistableBundle onLoadConfig(int subId, @Nullable CarrierIdentifier carrierId) {\n'
HELPER = '''
    // nowhere-cc2-sms-to-mms PATCH_VERSION 2 (NWP-20261130-15): no CarrierSettings entry turns a long text into an
    // MMS, and the platform default of both thresholds is -1 (never convert), so AOSP Messaging sent a 19-part text as
    // one multipart SMS that timed out before the radio (lynx 2026110402, 2026-11-06). Fill each threshold that the
    // bundle does not hold; every value a carrier supplies is kept, an explicit 0 or -1 (never convert) included.
    private static final int NOWHERE_SMS_TO_MMS_PARTS = 7;
    // 7 parts x 153 GSM-7 characters per concatenated part.
    private static final int NOWHERE_SMS_TO_MMS_LENGTH = 1071;

    private static PersistableBundle nowhereSmsToMms(@Nullable PersistableBundle b) {
        if (b == null) {
            b = new PersistableBundle();
        }
        boolean parts = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_PARTS);
        boolean length = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_LENGTH);
        Log.i(TAG, "nowhere: sms-to-mms thresholds (NWP-20261130-15): parts "
                + (parts ? "set " : "carrier ")
                + b.getInt(android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT)
                + ", length " + (length ? "set " : "carrier ")
                + b.getInt(android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT));
        return b;
    }

    private static boolean nowhereFillUnset(PersistableBundle b, String key, int value) {
        if (b.containsKey(key)) {
            return false;
        }
        b.putInt(key, value);
        return true;
    }
'''
if STAMP not in HELPER:
    die(2, 'internal error: the helper does not carry the PATCH_VERSION %s stamp -- aborting' % ver)

for name, a in (('class-line', ANCHOR_A), ('loader-return', ANCHOR_B), ('onLoadConfig(int, ...) signature', SIG)):
    if s.count(a) != 1:
        die(2, '%s ANCHOR found %d times in %s, expected 1 (upstream changed?) -- aborting, nothing written'
            % (name, s.count(a), p))
# The return must sit inside onLoadConfig(int subId, ...), the OS entry point. A return moved into another method
# needs a human, not a guess.
start = s.index(SIG)
end = s.find('\n    }\n', start)
if not (start < s.index(ANCHOR_B) < end):
    die(2, 'the loader return is not inside onLoadConfig(int subId, ...) in %s (upstream changed?) -- aborting, '
        'nothing written' % p)

out = s.replace(ANCHOR_A, ANCHOR_A + HELPER, 1).replace(ANCHOR_B, WRAPPED, 1)
open(p, 'w', encoding='utf-8', newline='').write(out)

# End state, read back from the disk.
r = open(p, encoding='utf-8', newline='').read()
bad = [what for what, ok in (
    ('the stamp once', r.count(STAMP) == 1),
    ('the helper once', r.count('private static PersistableBundle nowhereSmsToMms(') == 1),
    ('the wrapped return once', r.count(WRAPPED) == 1),
    ('no bare loader return', ANCHOR_B not in r),
) if not ok]
if bad:
    print('%s END STATE WRONG in %s (%s). The file is written; revert it:' % (TAG, p, ', '.join(bad)), file=sys.stderr)
    print(REVERT, file=sys.stderr)
    sys.exit(2)
print('%s patched %s: smsToMmsTextThreshold 7, smsToMmsTextLengthThreshold 1071 for every carrier that does not '
      'set them (PATCH_VERSION %s, NWP-20261130-15)' % (TAG, p, ver))
PY
