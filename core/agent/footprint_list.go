package main

import (
	"fmt"
	"net"
	"sort"
	"strings"
	"time"
)

// footprintOf, storePkgBytesOf and storeFolderBytesOf are the store-reading seams of the display verbs (GET-USAGE,
// GET-FOOTPRINT, the breakdown merge). The handlers hardcode the "s3" store, so only a test can substitute what they
// read; display_verbs_exec_test.go does, to run every refusal and success arm instead of searching for it.
var (
	footprintOf        = profileFootprint
	storePkgBytesOf    = storePkgBytes
	storeFolderBytesOf = storeFolderBytes
)

// handleGetFootprint backs the GET-FOOTPRINT verb (NWP-20260905-06): every store object key the signed-in
// profile occupies, with its size. It is the list half of what profileFootprint already computes -- six
// callers consume that map and every one of them collapses it to a byte total or a lease set, so the keys
// themselves have never been observable from anywhere.
//
// WHY IT EXISTS. A profile is content-addressed ciphertext whose refs derive from (name, pass) alone -- no
// endpoint, bucket or device input -- so moving a profile between stores is a byte copy plus a re-point
// (SET-STORE, handleSetStore in main.go), and re-pointing already ships. The missing piece was never a format or a
// parser: it was knowing WHICH OBJECTS TO COPY. That is this verb. docs/data-portability.md section iii is
// the recipe that consumes it.
//
// ⚠ IT TAKES NO NAME AND NO PASSPHRASE, AND THAT IS LOAD-BEARING. It answers only for the profile already
// signed in, read from the roam session exactly as GET-USAGE does (handleGetUsage, main.go). A verb that
// accepted an arbitrary (name, pass) over this socket would answer "0 objects" for a wrong passphrase and
// "N objects" for a right one -- a profile-existence oracle reachable from the gate, which is the blind-login
// property this project treats as load-bearing (AGENTS.md: "wrong/unknown credentials render an
// indistinguishable blank; the absence of a profile list is the security property"). The CLI verb below
// takes credentials because it is root-only and off-device; this one must not.
//
// Reply: "NONE" (nobody signed in) | "LOCAL" (a throwaway -- nothing of it is in the store) | a
// length-prefixed body of "objectkey<TAB>size" lines, sorted, matching the `footprint` CLI verb byte for
// byte. Length-prefixed because the list is unbounded: a 3-app profile measures ~600 MB across thousands of
// chunks (docs/profile-snapshot.md), so this is not a one-line answer like GET-USAGE's.
func handleGetFootprint(conn net.Conn, dest string) {
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // throwaway session: never sealed, nothing to copy
		return
	}
	// A full footprint walks every scope's head, manifest and chunk list -- the same store round-trip
	// GET-USAGE makes, and the reason its screen loads async. Deadline is the same 30 s the other store-touching reads use.
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	refs, measured := footprintOf("s3", name, pass, seFromSession(dest))
	if !measured {
		// ⚠ REFUSE RATHER THAN EMIT A SHORT ONE. This body is a COPY RECIPE, and an incomplete recipe is
		// the worst possible output: a copy made from it would be silently missing everything the
		// unopenable scope held, and nothing downstream can tell a short list from a small profile.
		fmt.Fprint(conn, "ERR-UNMEASURED\n")
		return
	}
	body := formatFootprint(refs)
	fmt.Fprintf(conn, "OK %d\n", len(body))
	fmt.Fprint(conn, body)
}

// formatFootprint renders a footprint map as sorted "objectkey<TAB>size" lines. Sorted so two runs of the
// same profile produce identical bytes -- a copy recipe diffs its input, and Go map order would make every
// run look like a change. Shared by the daemon verb and the CLI verb so the two cannot drift.
func formatFootprint(refs map[string]int64) string {
	keys := make([]string, 0, len(refs))
	for k := range refs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s\t%d\n", k, refs[k])
	}
	return b.String()
}
