package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"regexp"
)

// ssaidPrefillFile is roamd's census of the settings_ssaid.xml that SettingsProvider had pre-filled for the new
// user, in the state tmpfs (nowhere_roamd.sh, the seedssaid arm and ssaid_census; NWP-20261207-16). The arm removes
// it first at each SEED-SSAID and writes it again only when it reaches the staging.
const ssaidPrefillFile = "ssaid-prefill"

// ssaidPrefillMaxBytes bounds what a report reads of the file. The writer's line is far shorter.
const ssaidPrefillMaxBytes = 256

// The file's only accepted shapes, one regex each: one line, digits and fixed words only.
var (
	ssaidPrefillNoneRe   = regexp.MustCompile(`^v=1 none\n?$`)
	ssaidPrefillUnreadRe = regexp.MustCompile(`^v=1 unread=(link|notool|nostate|format|convert|parse)\n?$`)
	ssaidPrefillCountsRe = regexp.MustCompile(`^v=1 rows=([0-9]{1,9}) userkey=([0-9]{1,9}) apps=([0-9]{1,9}) distinct=([0-9]{1,9}) largest=([0-9]{1,9})\n?$`)
)

// ssaidPrefillStatus renders the last seedssaid's census as issue-report status keys (NWP-20261207-16; the backlog
// row "On a boot after a flash or an OTA, the bundled apps of every sign-in share one ANDROID_ID").
//
//	ssaid_prefill           "none" no stale table; "read" counted (the five keys below); "unread_<class>" not
//	                        counted (link, notool, nostate, format, convert, parse); "unreadable" a bad file
//	ssaid_prefill_rows      "<n>" <setting> rows in the table
//	ssaid_prefill_userkey   "<n>" of them, the userkey row
//	ssaid_prefill_apps      "<n>" the other rows: one per app
//	ssaid_prefill_distinct  "<n>" distinct values among the app rows
//	ssaid_prefill_largest   "<n>" the largest group of app rows sharing one value
//
// A missing file gives no keys (no seedssaid reached the staging since the last refusal or boot). Any other read
// error, an oversized file or any other shape gives ssaid_prefill=unreadable alone. It never copies any other text.
func ssaidPrefillStatus(path string) map[string]string {
	unreadable := map[string]string{"ssaid_prefill": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, ssaidPrefillMaxBytes+1))
	if err != nil || len(b) > ssaidPrefillMaxBytes {
		return unreadable
	}
	if ssaidPrefillNoneRe.Match(b) {
		return map[string]string{"ssaid_prefill": "none"}
	}
	if m := ssaidPrefillUnreadRe.FindSubmatch(b); m != nil {
		return map[string]string{"ssaid_prefill": "unread_" + string(m[1])}
	}
	m := ssaidPrefillCountsRe.FindSubmatch(b)
	if m == nil {
		return unreadable
	}
	return map[string]string{
		"ssaid_prefill":          "read",
		"ssaid_prefill_rows":     string(m[1]),
		"ssaid_prefill_userkey":  string(m[2]),
		"ssaid_prefill_apps":     string(m[3]),
		"ssaid_prefill_distinct": string(m[4]),
		"ssaid_prefill_largest":  string(m[5]),
	}
}
