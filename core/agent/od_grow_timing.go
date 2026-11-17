package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"regexp"
)

// odGrowTimingFile is roamd's summary of this session's watched odrestore copies in the state tmpfs
// (nowhere_roamd.sh, od_watched; NWP-20261202-34). The grant arm removes it at each sign-in.
const odGrowTimingFile = "od-grow-timing"

// odGrowTimingMaxBytes bounds what a report reads of the file. The writer's line is far shorter.
const odGrowTimingMaxBytes = 256

// odGrowTimingRe is the file's only accepted shape: one line, the five fields in this order, digits only.
var odGrowTimingRe = regexp.MustCompile(`^v=1 vols=([0-9]{1,9}) reads=([0-9]{1,9}) du_ms=([0-9]{1,12}) max_ms=([0-9]{1,12}) kib=([0-9]{1,12})\n?$`)

// odGrowTimingStatus renders this session's od_watched summary as issue-report status keys (NWP-20261202-34;
// docs/product-decisions.md 2026-11-01, h50 #1: a handset measurement of what the size walk costs every 10 seconds).
//
//	od_grow_vols       "<n>" watched odrestore copies that timed at least one size read
//	od_grow_reads      "<n>" timed `du -sk` reads, all copies
//	od_grow_du_ms      "<n>" the sum of those reads' times
//	od_grow_du_max_ms  "<n>" the longest single read
//	od_grow_kib        "<n>" the largest last good size of one copy, in KiB
//
// A missing file gives no keys (no watched copy timed a read this session). Any other read error, an oversized file
// or any other shape gives od_grow_timing=unreadable alone. It never copies any other text.
func odGrowTimingStatus(path string) map[string]string {
	unreadable := map[string]string{"od_grow_timing": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, odGrowTimingMaxBytes+1))
	if err != nil || len(b) > odGrowTimingMaxBytes {
		return unreadable
	}
	m := odGrowTimingRe.FindSubmatch(b)
	if m == nil {
		return unreadable
	}
	return map[string]string{
		"od_grow_vols":      string(m[1]),
		"od_grow_reads":     string(m[2]),
		"od_grow_du_ms":     string(m[3]),
		"od_grow_du_max_ms": string(m[4]),
		"od_grow_kib":       string(m[5]),
	}
}
