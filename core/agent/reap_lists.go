package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// isSessionFileList says a top-level name in the state tmpfs is one of the plaintext file-name lists a session leaves
// there. blobcache.*, contentcache.* and groupcache.* hold hashes, not rels, and are not lists.
func isSessionFileList(name string) bool {
	switch name {
	case "sealdelta.idx", "sealdelta.idx.tmp", "sealdelta.listed", "sealdelta.listed.tmp":
		return true
	}
	return strings.HasPrefix(name, "scancache.") || strings.HasPrefix(name, "heal-handled-")
}

// reapSessionLists removes a departed session's plaintext file-name lists from the state tmpfs at the reap (h59 #11,
// docs/product-decisions.md, 2026-11-05, under #39's roster rule; NWP-20261129-19): scancache.<tag> (every large file
// of the vault, #de and #media), heal-handled-<hash> (the rels the sign-in heal handled) and the walk's sealdelta
// lists. sealdelta.listed is not one of the decision's three: it is the same class of roster, written beside
// sealdelta.idx by the same op after the question was asked, so taking it too is an inference. In session the lists
// keep their form, which h56 #6 reads. The caller holds sessionMu and has already cleared a gone user's marker: on a
// usual reap the marker still names that user until then.
//
// ⚠ A reap while another session is live or parked removes NOTHING. The lists carry no owner, and a same-profile
// session reuses the same scancache and heal-handled names, so removing a live session's heal list would let its carry
// bring back a file the app deleted. They go at that session's own reap or at power-off. That residual is a question
// for the maintainer (the backlog row "A departed session's file-name lists stay in clear on the state tmpfs until
// power-off").
//
// A failed removal is counted, never named: an error from os holds the path. A later reap tries it again.
func reapSessionLists(dest string) (removed int, kept bool) {
	if _, _, _, state := readRoamSessionState(dest); state != roamSessionAbsent {
		kept = true // a damaged marker is still a session
	}
	if _, err := os.Lstat(filepath.Join(dest, ".coldlock")); !errors.Is(err, fs.ErrNotExist) {
		kept = true // and so is a .coldlock this could not read
	}
	if kept {
		fmt.Fprintln(os.Stderr, "[logind] reap: kept the session file lists -- a session is live or parked (h59 #11)")
		return 0, true
	}
	failed := 0
	entries, err := os.ReadDir(dest)
	if err != nil {
		failed++
	}
	for _, e := range entries {
		if !isSessionFileList(e.Name()) {
			continue
		}
		p := filepath.Join(dest, e.Name())
		fi, err := os.Lstat(p) // never a directory, never through a symlink
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				failed++
			}
			continue
		}
		if !fi.Mode().IsRegular() {
			continue
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			failed++
			continue
		}
		removed++
	}
	resetSealDeltaCaches() // or the next walk skips rewriting the index its cache says is written
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session file list(s) from the state tmpfs, %d failed (h59 #11)\n", removed, failed)
	} else {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session file list(s) from the state tmpfs (h59 #11)\n", removed)
	}
	return removed, false
}
