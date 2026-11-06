package main

import (
	"os"
	"strings"
	"sync"
)

// Account-level app tombstones (#91 slice 5c, closing Chester's 2026-09-06 decision).
//
// THE DECISION: "if they've deliberately uninstall an app - they would expect it to be gone. i wouldn't
// categorized this to be similar to on-demand (this will request the app when tapped) or even off on your app
// (thats a soft dont bring next round kind of a concept)." So an uninstall is a DELETION FROM THE ACCOUNT, and
// the three actions stay distinct (docs/product-decisions.md, 2026-09-06).
//
// WHY THE DROP LIST CANNOT DELIVER THAT ON ITS OWN. It is written at logoff, into the chooser's CE dir, and
// roamd clears it at roam-in: it is per-device and per-session by construction. So the handset that watched
// the uninstall honours it, and a handset that was ALREADY SIGNED IN never hears about it -- it still has the
// app installed, stages it at its next seal, and puts it straight back into the account head. The deletion is
// undone by a device that never knew.
//
// WHAT A TOMBSTONE ADDS. `chunkManifest.Gone` records pkg -> the unix time it was removed, IN THE HEAD. Every
// device reads that head on every seal, so the record propagates with no new channel, no cross-device
// messaging and no second head -- the same property that made the carry cheap.
//
// ⚠ AND IT IS CLEARED BY THE MACHINERY THAT ALREADY EXISTS, which is why this is small. Tombstones join the
// SAME set loadDropList builds, BEFORE its keep-set intersect -- and that intersect already refuses to drop a
// package that is currently kept ("never drop a package that is CURRENTLY kept"). So a user who reinstalls the
// app and keeps it clears the tombstone by doing exactly that, with no new rule and no timestamp arithmetic. A
// permanent record with no way back is how a tombstone design goes wrong, and this one cannot: the escape
// hatch is the user's own keep action.

var (
	sealTombMu  sync.Mutex
	sealTombSet map[string]int64
)

// setSealTombstones publishes the stored head's tombstones for THIS push. Always called, with nil when the
// scope or the flag does not carry them -- a push must never inherit the previous push's set, and this process
// serves many seals in a row (the login daemon runs handleExport inline).
func setSealTombstones(g map[string]int64) {
	sealTombMu.Lock()
	sealTombSet = g
	sealTombMu.Unlock()
}

// sealTombstones is the set in force for the seal currently running.
func sealTombstones() map[string]int64 {
	sealTombMu.Lock()
	defer sealTombMu.Unlock()
	return sealTombSet
}

// goneDropList is the UNINSTALL subset of the drop list: the packages named in the file NOWHERE_GONE_LIST points
// at that fileDropList() also holds. NWP-20261023-07.
//
// A NEW tombstone is minted from this set and from nothing wider. DECIDED 2026-09-26: an app switched Off leaves
// the store at the next roam but "never mints the account tombstone" -- an Off is a per-device soft decision, an
// uninstall is a deletion from the account. The drop list holds Offs and uninstalls alike, so minting from it
// would let an Off made on one handset delete the app from every other. roamd names the uninstalled subset; only
// its #apps push sets NOWHERE_GONE_LIST.
//
// Parsed exactly as fileDropList parses (trimmed lines, a line holding a path separator ignored) and intersected
// with it, so a gone list that drifts from the drop list cannot mint for a package this seal did not drop.
// Unset, empty, unreadable or disjoint gives nil: no new tombstone, which is the safe direction -- a missing one
// is the shipped behaviour, a wrong one deletes an app account-wide.
func goneDropList() map[string]bool {
	p := os.Getenv("NOWHERE_GONE_LIST")
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	drop := fileDropList()
	var out map[string]bool
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.ContainsAny(ln, "/\\") || !drop[ln] {
			continue
		}
		if out == nil {
			out = map[string]bool{}
		}
		out[ln] = true
	}
	return out
}

// tombstonesToPublish computes the Gone map for the head this seal is about to write. Pure, so the truth table
// is testable without a store.
//
//   - An existing tombstone SURVIVES, with its ORIGINAL timestamp. Refreshing it on every seal would turn "when
//     was this deleted" into "when did any device last seal", which is the field's only real content.
//   - It is DROPPED when the package is present in this seal: the suppression above cannot have let that
//     happen unless the keep-set rescued it, which means the user deliberately re-added the app.
//   - A package in the UNINSTALL subset of the drop list (goneDropList, NWP-20261023-07 -- an Off never mints
//     one, DECIDED 2026-09-26), that the stored head actually named, gets a NEW tombstone. Nothing the account
//     never had is tombstoned, so an unrelated device's local drop cannot plant a record.
func tombstonesToPublish(old map[string]int64, fileDrop, oldNamed, present map[string]bool, now int64) map[string]int64 {
	out := map[string]int64{}
	for pkg, at := range old {
		if present[pkg] {
			continue // deliberately re-added -> the tombstone is spent
		}
		out[pkg] = at
	}
	for pkg := range fileDrop {
		if present[pkg] || !oldNamed[pkg] {
			continue
		}
		if _, had := out[pkg]; !had {
			out[pkg] = now
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// headNamedPackages is every package the stored head accounts for, across all three places it can say so: the
// per-package byte index, the whole-scope app index, and the first path segment of an essential rel. A
// tombstone may only be minted for one of these.
func headNamedPackages(m chunkManifest) map[string]bool {
	out := make(map[string]bool, len(m.Pkg)+len(m.Apps))
	for pkg := range m.Pkg {
		out[pkg] = true
	}
	for pkg := range m.Apps {
		out[pkg] = true
	}
	for rel := range m.Ess {
		if pkg := carryPkgOf(rel); pkg != "" {
			out[pkg] = true
		}
	}
	for rel := range m.Deferred {
		if pkg := carryPkgOf(rel); pkg != "" {
			out[pkg] = true
		}
	}
	return out
}
