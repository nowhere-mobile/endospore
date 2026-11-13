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
// there. contentcache.* and groupcache.* hold hashes, not rels, and are not lists: isSessionCache takes them at the reap
// (h60 #8). Only blobcache.* stays.
func isSessionFileList(name string) bool {
	switch name {
	case "sealdelta.idx", "sealdelta.idx.tmp", "sealdelta.listed", "sealdelta.listed.tmp",
		"media-bg.list", "media-bg.list.tmp", "media-bg.list.handoff":
		return true
	}
	return strings.HasPrefix(name, "scancache.") || strings.HasPrefix(name, "heal-handled-")
}

// isSessionCache says a top-level name in the state tmpfs is one of a session's content and group caches, its seal
// counter or its #media no-change record, their .tmp forms included (h60 #8).
func isSessionCache(name string) bool {
	for _, prefix := range []string{"contentcache.", "groupcache.", "sealcount.", "mnochange."} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

// reapSessionLists removes a departed session's plaintext file-name lists from the state tmpfs at the reap (h59 #11,
// docs/product-decisions.md, 2026-11-05, under #39's roster rule; NWP-20261129-19): scancache.<tag> (every large file
// of the vault, #de and #media), heal-handled-<hash> (the rels the sign-in heal handled) and the walk's sealdelta
// lists. sealdelta.listed is not one of the decision's three: it is the same class of roster, written beside
// sealdelta.idx by the same op after the question was asked, so taking it too is an inference. In session the lists
// keep their form, which h56 #6 reads. The same pass removes the session's caches (isSessionCache; h60 #8,
// docs/product-decisions.md, 2026-11-06; NWP-20261201-35): the content cache is a plaintext fingerprint testable with no
// key. A later sign-in of the same profile in the same boot pays for that by re-reading its small files on its first
// save. The caller holds sessionMu and has already cleared a gone user's marker: on a usual reap the marker still names
// that user until then.
//
// ⚠ A reap while another session is live or parked removes NOTHING. The lists carry no owner, and a same-profile
// session reuses the same scancache and heal-handled names, so removing a live session's heal list would let its carry
// bring back a file the app deleted. They go at that session's own reap or at power-off. That kept case is the residual
// decided by h60 #7 (docs/product-decisions.md, 2026-11-06, "twenty answers to harvest 60 ..."): the lists stay until
// the next reap with no session live or parked, or power-off. It is bounded because a sign-in over a cold lock
// supersedes the parked session once it succeeds (2026-10-10), so two sessions coexist only during that sign-in or
// through the gap row "A sign-in during an explicit cold lock’s wait does not supersede the old session directly".
// Per-session owner records were not chosen.
// The caches follow the same rule (h60 #7, h62 #7): a cache stays until the next reap with no other session, or
// power-off.
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
		fmt.Fprintln(os.Stderr, "[logind] reap: kept the session file lists and caches -- a session is live or parked (h59 #11, h60 #8)")
		return 0, true
	}
	failed, caches, cfailed := 0, 0, 0
	entries, err := os.ReadDir(dest)
	if err != nil {
		failed++
	}
	for _, e := range entries {
		count, lost := &removed, &failed
		if !isSessionFileList(e.Name()) {
			if !isSessionCache(e.Name()) {
				continue
			}
			count, lost = &caches, &cfailed
		}
		p := filepath.Join(dest, e.Name())
		fi, err := os.Lstat(p) // never a directory, never through a symlink
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				*lost++
			}
			continue
		}
		if !fi.Mode().IsRegular() {
			continue
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			*lost++
			continue
		}
		*count++
	}
	resetSealDeltaCaches() // or the next walk skips rewriting the index its cache says is written
	// On a device seal and restore run in roamd's fresh agent processes and the daemon has no NOWHERE_BLOBCACHE
	// (nowhere_login.sh), so this drops only the daemon's own RAM copy; in-process (the tests) it makes a later restore
	// re-seed the file instead of skipping mappings still in memory.
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheLoadedTag = ""
	contentCacheMu.Unlock()
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session file list(s) from the state tmpfs, %d failed (h59 #11)\n", removed, failed)
	} else {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session file list(s) from the state tmpfs (h59 #11)\n", removed)
	}
	if cfailed > 0 {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session cache file(s) from the state tmpfs, %d failed (h60 #8)\n", caches, cfailed)
	} else {
		fmt.Fprintf(os.Stderr, "[logind] reap: removed %d session cache file(s) from the state tmpfs (h60 #8)\n", caches)
	}
	return removed, false
}
