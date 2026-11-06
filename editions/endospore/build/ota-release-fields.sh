#!/usr/bin/env bash
# ota-release-fields.sh <version> [<ota-mandatory file>] -- print the installer manifest's "ota" object (one line of
# JSON) for one release. NWP-20261011-05; called by make-web-package.sh, which puts it in the manifest the operator
# signs with the release key -- that signature is what a phone checks before it believes a word of it.
#
#   {"version": "0.5.45", "severity": "mandatory", "published": "2026-10-12", "reason": "...", "consequence": "..."}
#
# No file (or a path that does not exist) = an ordinary release: {"version": ..., "severity": "none", "published": ...}.
# `published` is today's UTC date, or $NOWHERE_OTA_PUBLISHED (YYYY-MM-DD) when publication is planned for another day:
# a phone counts the deadline from the later of it and the day that phone first sees the release (a future date
# pushes every phone's deadline out, so never set one).
#
# This is a WRITER, not the authority. The authority is the Go parser (core/agent/ota_mandatory.go) that the phone and
# e4-ota-publish.sh both run: the publish refuses a signed manifest whose object disagrees with the committed file.
# This script applies the reader's own rules (the file's shape, and checkOtaText's for the reason and the consequence)
# so a file the phone would refuse fails here, before anything is signed.
set -euo pipefail

VERSION="${1:?usage: ota-release-fields.sh <version> [<ota-mandatory file>]}"
SRC="${2:-}"
PUBLISHED="${NOWHERE_OTA_PUBLISHED:-$(date -u +%F)}"
command -v python3 >/dev/null 2>&1 || { echo "[ota-release-fields] python3 is required" >&2; exit 1; }

python3 - "$VERSION" "$SRC" "$PUBLISHED" <<'PY'
import datetime, json, os, re, sys, unicodedata
version, src, published = sys.argv[1], sys.argv[2], sys.argv[3]
def die(msg):
    sys.stderr.write("[ota-release-fields] %s\n" % msg)
    sys.exit(1)
# Mirrors core/agent/ota_mandatory.go's checkOtaText and ota_notes.go's otaNotesClaimWords; the reader is the
# authority. TestOtaReleaseFieldsClaimWordsMatchTheReader holds these three lines equal to the Go.
TEXT_MAX = 200
CLAIM_WORDS = r"\b(privacy|private|privately|anonymous|anonymity|anonymously|secure|securely|security|encrypt\w*|decrypt\w*|tracking|tracker\w*|untrack\w*|surveil\w*|safe|safer|safely|safety|protect\w*|confidential\w*|zero[- ]knowledge|no[- ]logs?|can'?t see|cannot see|never see)\b"
# RE2's (?i) also folds U+017F to s and U+212A to k; re.ASCII folds ASCII only, so those two are spelled out. Safe while
# the pattern's only escapes are \b and \w and its only class is [- ].
CLAIM_FOLDS = {"k": "\u212a", "s": "\u017f"}
CLAIM_RE = re.compile("".join("[%s%s]" % (c, CLAIM_FOLDS[c]) if c in CLAIM_FOLDS else c for c in CLAIM_WORDS), re.IGNORECASE | re.ASCII)
if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,3}", version):
    die("version %r is not x.y.z" % version)
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", published):
    die("published %r is not YYYY-MM-DD" % published)
try:
    datetime.date.fromisoformat(published)
except ValueError:
    die("published %r is not a real date" % published)
obj = {"version": version, "severity": "none", "published": published}
if src and os.path.exists(src):
    try:
        with open(src, encoding="utf-8", newline="") as f:
            text = f.read()
    except UnicodeDecodeError:
        die("%s: not UTF-8" % src)
    lines = text.replace("\r\n", "\n").rstrip("\n").split("\n")
    if len(lines) != 4:
        die("%s: want exactly 4 lines (version, severity, reason, consequence), got %d" % (src, len(lines)))
    vals = {}
    for i, key in enumerate(("version", "severity", "reason", "consequence")):
        if not lines[i].startswith(key + " "):
            die("%s: line %d must be `%s <value>`" % (src, i + 1, key))
        vals[key] = lines[i][len(key) + 1:]
    if vals["version"] != version:
        die("%s describes %s, not %s" % (src, vals["version"], version))
    if vals["severity"] not in ("mandatory", "critical"):
        die("%s: severity must be mandatory or critical" % src)
    for key in ("reason", "consequence"):
        v = vals[key]
        if not v.strip():
            die("%s: %s is empty" % (src, key))
        if v != v.strip():
            die("%s: %s has leading or trailing space" % (src, key))
        if len(v) > TEXT_MAX:
            die("%s: %s is %d characters, over %d" % (src, key, len(v), TEXT_MAX))
        if any(unicodedata.category(c) == "Cc" for c in v):
            die("%s: %s has a control character" % (src, key))
        m = CLAIM_RE.search(v)
        if m:
            die("%s: %s says %r: no privacy or security claims (docs/privacy-claims.md)" % (src, key, m.group(0)))
    obj["severity"], obj["reason"], obj["consequence"] = vals["severity"], vals["reason"], vals["consequence"]
print(json.dumps(obj, ensure_ascii=False))
PY
