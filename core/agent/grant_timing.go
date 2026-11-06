package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"regexp"
)

// grantTimingFile is roamd's grant-op summary in the state tmpfs (nowhere_roamd.sh, the grant arm; NWP-20261119-07).
const grantTimingFile = "grant-timing"

// grantTimingMaxBytes bounds what a report reads of the file. The writer's line is far shorter.
const grantTimingMaxBytes = 256

// grantTimingRe is the file's only accepted shape: one line, the four fields in this order, digits only.
var grantTimingRe = regexp.MustCompile(`^v=1 bundles=([0-9]{1,9}) keystore_ms=([0-9]{1,12}) perms_ms=([0-9]{1,12}) total_ms=([0-9]{1,12})\n?$`)

// grantTimingStatus renders the last grant op's summary as issue-report status keys (NWP-20261119-07, backlog: 0.5.49's
// grant op runs the Keystore sweep, ...): how many restored #keys bundles the sign-in staged and how long the sweep,
// the runtime-permission grant and the whole op took.
//
//	grant_bundles      "<n>" restored bundles in keystore-in/<uid> before the sweep
//	grant_keystore_ms  "<n>" keystore_register_all (roam.log's TIMING grant-keystore, plus that line's own date)
//	grant_perms_ms     "<n>" grant_perms_for (roam.log's TIMING grant-135, likewise)
//	grant_total_ms     "<n>" the whole arm, its first line to its reply
//
// A missing file gives no keys (no grant ran this boot, or the last one was cut off before its end). Any other read
// error, an oversized file or any other shape gives grant_timing=unreadable alone. It never copies any other text.
func grantTimingStatus(path string) map[string]string {
	unreadable := map[string]string{"grant_timing": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, grantTimingMaxBytes+1))
	if err != nil || len(b) > grantTimingMaxBytes {
		return unreadable
	}
	m := grantTimingRe.FindSubmatch(b)
	if m == nil {
		return unreadable
	}
	return map[string]string{
		"grant_bundles":     string(m[1]),
		"grant_keystore_ms": string(m[2]),
		"grant_perms_ms":    string(m[3]),
		"grant_total_ms":    string(m[4]),
	}
}
