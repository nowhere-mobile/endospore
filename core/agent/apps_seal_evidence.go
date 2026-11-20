package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// NWP-20261208-01: THE LAST #apps SEAL'S CARRY COUNTS, AS A SESSION ISSUE REPORT'S STATUS KEYS.
//
// The backlog row "P1: On-demand apps that are not on the phone at a sign-out are dropped from the `#apps` code list,
// ..." closes on "the cause is named from a sign-out's own counts". pushProfile prints those counts only to roam.log,
// and only when they are not zero, and a report keeps the last 299 lines of each log: after an Auto sweep they are gone.
//
// So an #apps seal also writes its counts to one file in the state dir, named by a hash of the scope's profileRefV2
// (the deferredPresenceFile scheme): no profile name, no ref. The next #apps restore of the SAME profile on this
// handset (NOWHERE_PHASE=appcode) moves the line into that sign-in's summary file (signin_summary.go), beside the
// restored head's app-index count, and a session issue report reads both into never-trimmed status keys:
//
//	v=1 appsseal stored=<n> dormant=<n> adopted=<n> carried=<n> dropped=<n> published=<n> lost=<n> vanished=<n> guard=<none|passed|refused>
//	v=1 appsindex pkgs=<n>
//
// guard is "none" when the seal wrote the carry counts and returned before the #apps presence guard, "passed" when
// the guard let it through (not proof of upload: a later step can still fail), "refused" when the guard refused it.
// Each #apps seal first removes the profile's older record, so a seal refused before the carry leaves none behind.
//
// The file lives in the state dir (in roamd /data/nowhere/state, the RAM tmpfs that docs/threat-model.md section 2
// excludes, as release_gen.go's header says), so it is wiped at power-off and needs no threat-model row. Counts and
// fixed words only. Every function is inert when stateDir is "" (the host CLI), and every error is ignored: a
// diagnostic never fails a seal or a restore.

// appsSealCounts is one #apps seal's carry counts. guard is one of "none", "passed", "refused".
type appsSealCounts struct {
	stored, dormant, adopted, carried, dropped, published, lost, vanished int
	guard                                                                 string
}

// appsSealMaxBytes bounds what takeAppsSeal reads; the widest line is about 140 bytes.
const appsSealMaxBytes = 512

// appsSealFile names a scoped profile's record in the state dir without its name or ref.
func appsSealFile(profile, pass string) string {
	sum := sha256.Sum256([]byte(profileRefV2(profile, pass)))
	return "apps-seal-" + hex.EncodeToString(sum[:8])
}

// appsSealLine is the record's one line, without its newline.
func appsSealLine(c appsSealCounts) string {
	return fmt.Sprintf("v=1 appsseal stored=%d dormant=%d adopted=%d carried=%d dropped=%d published=%d lost=%d vanished=%d guard=%s",
		c.stored, c.dormant, c.adopted, c.carried, c.dropped, c.published, c.lost, c.vanished, c.guard)
}

// writeAppsSeal replaces the profile's record atomically: a temp file in the same dir, 0600, then a rename.
func writeAppsSeal(stateDir, profile, pass string, c appsSealCounts) {
	if stateDir == "" {
		return
	}
	f, err := os.CreateTemp(stateDir, ".apps-seal-*")
	if err != nil {
		return
	}
	tmp := f.Name()
	_, werr := f.Write([]byte(appsSealLine(c) + "\n"))
	cerr := f.Chmod(0o600)
	if err := f.Close(); werr != nil || cerr != nil || err != nil {
		_ = os.Remove(tmp)
		return
	}
	if err := os.Rename(tmp, filepath.Join(stateDir, appsSealFile(profile, pass))); err != nil {
		_ = os.Remove(tmp)
	}
}

// removeAppsSeal removes the profile's record, if any.
func removeAppsSeal(stateDir, profile, pass string) {
	if stateDir == "" {
		return
	}
	_ = os.Remove(filepath.Join(stateDir, appsSealFile(profile, pass)))
}

// takeAppsSeal returns the profile's record line and removes the file, whatever it held. Only the exact appsseal
// shape is returned; anything else is dropped.
func takeAppsSeal(stateDir, profile, pass string) (string, bool) {
	if stateDir == "" {
		return "", false
	}
	p := filepath.Join(stateDir, appsSealFile(profile, pass))
	f, err := os.Open(p)
	if err != nil {
		_ = os.Remove(p)
		return "", false
	}
	b, rerr := io.ReadAll(io.LimitReader(f, appsSealMaxBytes+1))
	_ = f.Close()
	_ = os.Remove(p)
	if rerr != nil || len(b) > appsSealMaxBytes || !strings.HasSuffix(string(b), "\n") {
		return "", false
	}
	line := strings.TrimSuffix(string(b), "\n")
	if !signinSummaryAppsSealRe.MatchString(line) {
		return "", false
	}
	return line, true
}

// signinSummaryAppendApps appends the #apps restore's app-index count and, when this profile has one, its last
// #apps seal's record to NOWHERE_SIGNIN_SUMMARY. Called in the restore verb's CDC branch after signinSummaryAppend,
// with that function's gates plus the #apps phase only, so any other restore leaves the record in place.
func signinSummaryAppendApps(m chunkManifest, stateDir, profile, pass string) {
	path := os.Getenv("NOWHERE_SIGNIN_SUMMARY")
	if path == "" || !filepath.IsAbs(path) {
		return
	}
	if os.Getenv("NOWHERE_PHASE") != "appcode" {
		return
	}
	out := fmt.Sprintf("v=1 appsindex pkgs=%d\n", len(m.Apps))
	if line, ok := takeAppsSeal(stateDir, profile, pass); ok {
		out += line + "\n"
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return
	}
	_, _ = f.Write([]byte(out))
	_ = f.Close()
}
