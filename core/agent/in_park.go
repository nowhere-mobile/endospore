package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// NWP-20261129-17 (docs/backlog.md, "A sign-in whose restore fails has already moved the live or cold-locked session's
// per-login state out of `$STATE`"; docs/product-decisions.md 2026-11-05, h59 #2). The `in` op's commit arm moves the
// departed session's per-login entries into $STATE/.in-park before the restore. roamd puts them back when the restore
// does not land. When it lands, roamd answers OK and keeps the park, because only the daemon knows whether that OK
// became a session: dropInPark runs once the marker is written, and putBackInPark runs on every path where the sign-in
// did not become one.

// inParkDir is the park, under $STATE.
const inParkDir = ".in-park"

// inParkNames is the six per-login entries, in the order of roamd's put-back (TestInParkNamesMatchRoamd).
var inParkNames = []string{"restore-receipts", "media.restore-ok", ".btlogoff", ".had_account", ".fido2hmac", ".fido2slots"}

// putBackInPark is roamd's not-landed put-back: each name is cleared of what the attempt left and the parked entry
// moved back, so a name absent before is absent after. It returns how many entries came back. No park: nothing happens.
func putBackInPark(dest, why string) int {
	park := filepath.Join(dest, inParkDir)
	if _, err := os.Lstat(park); err != nil {
		return 0
	}
	n := 0
	for _, entry := range inParkNames {
		os.RemoveAll(filepath.Join(dest, entry))
		err := os.Rename(filepath.Join(park, entry), filepath.Join(dest, entry))
		if err == nil {
			n++
		} else if !errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "[logind] %s: could not put back %s (h59 #2)\n", why, entry)
		}
	}
	os.RemoveAll(park)
	fmt.Fprintf(os.Stderr, "[logind] %s: per-login state put back (%d entries) (h59 #2)\n", why, n)
	return n
}

// dropInPark discards the park of a sign-in the daemon has recorded.
func dropInPark(dest string) {
	park := filepath.Join(dest, inParkDir)
	if _, err := os.Lstat(park); err != nil {
		return
	}
	os.RemoveAll(park)
	fmt.Fprintf(os.Stderr, "[logind] roam-in recorded: the departed session's per-login state dropped (h59 #2)\n")
}
