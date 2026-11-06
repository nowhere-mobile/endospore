package main

import (
	"regexp"
	"strings"
	"testing"
)

// NWP-20261020-18. A create over a deleted name runs a full deleteProfile purge first, silently; its wall time
// was never measured. The purge line now carries "(<ms> ms)" so login.log can time it. It must stay free of the
// name and the passphrase (blind login), and a name that was never deleted must print no purge line at all.

const purgeLineMarker = "this name was deleted -> purging leftovers first"

func TestRecreateAfterDeleteLogsTheTimedPurgeOnce(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "recreatetimed", "correct horse battery staple"

	fresh := captureStderr(t, func() { createVault(base, name, pass) })
	if strings.Contains(fresh, purgeLineMarker) {
		t.Fatalf("a create of a never-used name printed a purge line:\n%s", fresh)
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want deleted", got)
	}

	out := captureStderr(t, func() { createVault(base, name, pass) })
	if n := strings.Count(out, purgeLineMarker); n != 1 {
		t.Fatalf("purge line printed %d times, want 1:\n%s", n, out)
	}
	re := regexp.MustCompile(`(?m)^.*` + purgeLineMarker + `: .* \(\d+ ms\)$`)
	line := re.FindString(out)
	if line == "" {
		t.Fatalf("purge line has no \"(<digits> ms)\" suffix:\n%s", out)
	}
	if strings.Contains(line, name) || strings.Contains(line, pass) {
		t.Fatalf("purge line leaks the name or passphrase: %s", line)
	}
}
