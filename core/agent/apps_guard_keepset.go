package main

import "os"

// readAppsKeepSet reads the live keep-set the #apps push is handed (NOWHERE_KEEP_LIST, the same file and the
// same parser loadDropList uses). Unset (not merely empty) is (nil, true): the CLI and the older tests, where a deliberate marker
// keeps speaking for the whole scope. Set but unreadable, an empty path included, is (nil, false): the caller cannot tell what is still
// kept, so a deliberate marker must excuse nothing.
func readAppsKeepSet() (map[string]string, bool) {
	kp, present := os.LookupEnv("NOWHERE_KEEP_LIST")
	if !present {
		return nil, true
	}
	kb, err := os.ReadFile(kp)
	if err != nil {
		return nil, false
	}
	return parseKeepModes(kb), true
}

// appsVanishedExcused reports whether package p, which the stored #apps head carries and this seal lacks, is
// excused by a declared removal. An inferred marker's own list (declaredOff) always excuses what it named. A
// DELIBERATE marker is the user's word about what THIS handset removed, so it excuses only a package the live
// keep-set no longer names: one still in the keep-set is one the user still keeps, and its absence from the
// stage means this handset never received it (the #apps presence guard in pushProfile).
func appsVanishedExcused(p string, declaredOff map[string]bool, deliberate bool, kept map[string]string, keptOK bool) bool {
	if declaredOff[p] {
		return true
	}
	if !deliberate {
		return false
	}
	if !keptOK {
		return false
	}
	_, still := kept[p]
	return !still
}
