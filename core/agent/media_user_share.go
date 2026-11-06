package main

// NWP-20261119-18: HOW MUCH OF AN ESSENTIAL #media RESTORE IS USER MEDIA (Q106, first slice).
//
// The backlog row "A 179-second login, 95% of it bulk media restored INLINE before the gate opens" measured
// odimport9's 1.8 GB essential #media restore at 83-88 s of a sign-in. Q106 (docs/product-decisions.md,
// 2026-10-20) decided that user media restores in the background after the gate opens. Nothing in the
// restore said how much of that essential set the decision would move; this file is the measure and the
// classifier the background restore will reuse.
//
// It reads only the head's per-file essential index (chunkManifest.Ess), which a #media seal writes under
// NOWHERE_CARRY_ESSENTIAL_MEDIA (threshold 0, so Ess names every essential regular file -- media_carry.go).
// Nothing is fetched. Deferred entries are not counted: they are already off the sign-in's path. A head
// without Ess is reported as not measured, never as "no user media". Diagnostics only: what is restored,
// and when, does not change.

import (
	"fmt"
	"strings"
)

// q106UserMediaDirs is Q106's list, verbatim and case-sensitive: a rel is user media when its FIRST path
// component is exactly one of these, or when it lies under Android/media/. Android/data and Android/obb are
// app data, never user media; mediaKeepEagerDirs (media_tier.go) is app-critical, never user media.
var q106UserMediaDirs = []string{"DCIM", "Pictures", "Movies", "Music", "Download"}

const q106AndroidMedia = "Android/media/"

// isUserMediaRel reports whether rel (relative to /data/media/<uid>, as Ess keys are) is Q106 user media.
// Component-bounded: "DCIMX/a" and "Android/mediafoo/x" are not.
func isUserMediaRel(rel string) bool {
	first, _, _ := strings.Cut(rel, "/")
	for _, d := range q106UserMediaDirs {
		if first == d {
			return true
		}
	}
	return strings.HasPrefix(rel, q106AndroidMedia)
}

// mediaUserShare splits the head's essential files into user media and the rest, by plaintext size.
// indexed is false when the head carries no Ess index.
func mediaUserShare(m chunkManifest) (userFiles int, userBytes int64, otherFiles int, otherBytes int64, indexed bool) {
	if len(m.Ess) == 0 {
		return 0, 0, 0, 0, false
	}
	for rel, r := range m.Ess {
		if isUserMediaRel(rel) {
			userFiles++
			userBytes += r.Size
		} else {
			otherFiles++
			otherBytes += r.Size
		}
	}
	return userFiles, userBytes, otherFiles, otherBytes, true
}

// mediaUserShareLine is the restore's log line. It carries counts only: no profile name and no rel.
func mediaUserShareLine(m chunkManifest) string {
	uf, ub, of, ob, indexed := mediaUserShare(m)
	if !indexed {
		return "restore: #media essential: no per-file index in this head (Q106 share not measured)"
	}
	return fmt.Sprintf("restore: #media essential: %d user-media file(s) %d B %s, %d other file(s) %d B (Q106)",
		uf, ub, "(DCIM, Pictures, Movies, Music, Download, Android/media)", of, ob)
}
