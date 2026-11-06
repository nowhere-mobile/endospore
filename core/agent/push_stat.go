package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// NWP-20261123-06: the per-scope split on the daemon's periodic seal line.
//
// One periodic save held the roamd worker for 25.8 minutes and the issue report could not say where the time went:
// login.log keeps every periodic seal line, but only roam.log's push summaries (pushSplit) say how long each scope
// took and what it uploaded, and roam.log's tail had rolled past that save. So each push now also leaves its figures
// in a small file roamd names (NOWHERE_PUSH_STAT), roamd's out op folds every scope's wall time and upload KiB into
// $STATE/seal-split, and syncLoop appends that to the login.log line. Diagnostics only: no verdict reads any of it.
//
// Only labels (vault, de, media, sys, apps) and numbers travel. readSealSplit drops a file holding anything else, so
// a profile name or a path can never reach login.log through this line.

const (
	sealSplitFile = "seal-split"
	sealSplitMax  = 256 // the five-scope split is about 130 bytes with 10-digit figures
)

// sealSplitVerdicts are the verbs roamd's out op writes to RES itself (the six `> "$RES"` writes of its out arm; an
// ` PARTIAL:...` tail reaches these through sealVerb). Only such a reply comes after that op's own seal-split write in
// the same run. Every other answer (ERR-TIMEOUT, SKIP-SUPERSEDED, SKIP-REAPING, ERR-LANE, workerBusy, ...) comes from
// the daemon without this cycle's out arm, so a split file then present belongs to some other run.
var sealSplitVerdicts = map[string]bool{
	"OK":           true,
	"SKIP-STOPPED": true,
	"ERR-NOCREDIT": true,
	"ERR-REFUSED":  true,
	"ERR-PUSH":     true,
}

// pushStatFigures is pushSplit's twin, in numbers: the upload KiB, the upload ms and the local ms of this push, from
// the same atomics and the same formula (local = total - upload, never negative).
func pushStatFigures(t0 time.Time) (kib, upMs, localMs int64) {
	up := time.Duration(atomic.LoadInt64(&capFlushNanos))
	local := time.Since(t0) - up
	if local < 0 {
		local = 0
	}
	return atomic.LoadInt64(&capFlushBytes) >> 10, up.Round(time.Millisecond).Milliseconds(),
		local.Round(time.Millisecond).Milliseconds()
}

// writePushStat writes one line, `kib=<n> up=<n> local=<n>`, to path: through path.tmp and a rename, so roamd never
// reads half a line.
func writePushStat(path string, uploadKiB, uploadMs, localMs int64) error {
	tmp := path + ".tmp"
	line := fmt.Sprintf("kib=%d up=%d local=%d\n", uploadKiB, uploadMs, localMs)
	if err := os.WriteFile(tmp, []byte(line), 0600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// writePushStatFromEnv writes this push's figures where NOWHERE_PUSH_STAT says; unset, it writes nothing. The path
// holds a scope label only (pushstat.<label> under roamd's RAM state dir), never a profile.
func writePushStatFromEnv(t0 time.Time) {
	p := os.Getenv("NOWHERE_PUSH_STAT")
	if p == "" {
		return
	}
	kib, up, local := pushStatFigures(t0)
	if err := writePushStat(p, kib, up, local); err != nil {
		fmt.Fprintf(os.Stderr, "push: push stat not written (NWP-20261123-06): %v\n", err)
	}
}

// sealSplitEntry is one scope of the split roamd's out op writes: `<label>=<ms>ms/<kib>KiB`, or for #apps
// `apps=stage <ms>ms+push <ms>ms/<kib>KiB`; `?` stands for a push that left no stat file.
var sealSplitEntry = regexp.MustCompile(`^((vault|de|media|sys)=[0-9]+ms|apps=stage [0-9]+ms\+push [0-9]+ms)/([0-9]+|\?)KiB$`)

// readSealSplit returns <dest>/seal-split without its trailing newline, or "" when the file is missing, empty, longer
// than sealSplitMax, holds a byte outside [a-z0-9=/+.,? ] and the K and B of "KiB", or holds an entry that is not a
// scope label and its numbers (sealSplitEntry): a lower-case name or a path passes the byte check, not the entries.
// It does not remove the file (takeSealSplit does).
func readSealSplit(dest string) string {
	f, err := os.Open(filepath.Join(dest, sealSplitFile))
	if err != nil {
		return ""
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, sealSplitMax+2))
	if err != nil {
		return ""
	}
	if n := len(b); n > 0 && b[n-1] == '\n' {
		b = b[:n-1]
	}
	if len(b) == 0 || len(b) > sealSplitMax {
		return ""
	}
	for _, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '=', c == '/', c == '+', c == '.', c == ',', c == '?', c == ' ', c == 'K', c == 'B':
		default:
			return ""
		}
	}
	for _, e := range strings.Split(string(b), ",") {
		if !sealSplitEntry.MatchString(e) {
			return ""
		}
	}
	return string(b)
}

// takeSealSplit is readSealSplit, then the file is removed: always, a dropped file too, so no later line reads it.
func takeSealSplit(dest string) string {
	s := readSealSplit(dest)
	os.Remove(filepath.Join(dest, sealSplitFile))
	return s
}

// sealSplitKiB sums a validated split's upload KiB (readSealSplit's result): ok is false for an empty split, for any
// entry whose push left no stat file (?KiB), or for a sum longer than the day summary's 15 digits.
func sealSplitKiB(split string) (int64, bool) {
	if split == "" {
		return 0, false
	}
	var sum int64
	for _, e := range strings.Split(split, ",") {
		m := sealSplitEntry.FindStringSubmatch(e)
		if m == nil || m[3] == "?" {
			return 0, false
		}
		n, err := strconv.ParseInt(m[3], 10, 64)
		if err != nil || n > 999999999999999-sum {
			return 0, false
		}
		sum += n
	}
	return sum, true
}

// sealSplitSuffixFor is the periodic line's tail: " split: <split>", or "" when there is no split or when out is
// not a verdict roamd's out arm wrote (sealSplitVerdicts). Without it the line is byte-identical to the older one.
func sealSplitSuffixFor(out, split string) string {
	if split == "" || !sealSplitVerdicts[sealVerb(out)] {
		return ""
	}
	return " split: " + split
}
