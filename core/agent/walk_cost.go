package main

// NWP-20261202-15 (h49 #4 step 2): where an incremental push's walk time goes. pushProfile takes a walkCostSnap
// before and after the walk and logs walkCostLine beside the group-cache line: the groups read and their time,
// the rest of the walk, the process CPU and the /proc/pressure stall over it. Counts and times only -- no rel,
// no app name. A value the device cannot give (no PSI, an older kernel's missing cpu `full` line, a failed
// getrusage) prints n/a, never 0, so an unknown cannot read as "no stall" or "no CPU".

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// walkCostVal is one counter reading. ok=false is unknown (a missing file, line or field), never 0.
type walkCostVal struct {
	d  time.Duration
	ok bool
}

// walkCostSnap is one reading of the process CPU and the PSI totals.
type walkCostSnap struct {
	user, sys walkCostVal
	psi       [3][2]walkCostVal // walkCostPSIRes order x (some, full)
}

var walkCostPSIRes = [3]string{"io", "memory", "cpu"}

// walkCostPSIDir and walkCostRusage are package vars so tests can replace them.
var walkCostPSIDir = "/proc/pressure"

var walkCostRusage = func() (user, sys time.Duration, ok bool) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, 0, false
	}
	return time.Duration(ru.Utime.Nano()), time.Duration(ru.Stime.Nano()), true
}

// walkCostNow reads the process CPU and each PSI file once.
func walkCostNow() walkCostSnap {
	var s walkCostSnap
	if u, sy, ok := walkCostRusage(); ok {
		s.user, s.sys = walkCostVal{u, true}, walkCostVal{sy, true}
	}
	for i, res := range walkCostPSIRes {
		b, err := os.ReadFile(filepath.Join(walkCostPSIDir, res))
		if err != nil {
			continue
		}
		s.psi[i][0] = walkCostPSITotal(b, "some")
		s.psi[i][1] = walkCostPSITotal(b, "full")
	}
	return s
}

// walkCostPSITotal returns the `total=` microseconds of the PSI line whose first field is kind. A missing line or
// an unparsable total is unknown.
func walkCostPSITotal(b []byte, kind string) walkCostVal {
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || f[0] != kind {
			continue
		}
		for _, kv := range f[1:] {
			if v, found := strings.CutPrefix(kv, "total="); found {
				us, err := strconv.ParseUint(v, 10, 63)
				if err != nil {
					return walkCostVal{}
				}
				return walkCostVal{time.Duration(us) * time.Microsecond, true}
			}
		}
		return walkCostVal{}
	}
	return walkCostVal{}
}

// walkCostSub is after minus before; unknown when either side is unknown.
func walkCostSub(before, after walkCostVal) walkCostVal {
	if !before.ok || !after.ok {
		return walkCostVal{}
	}
	return walkCostVal{after.d - before.d, true}
}

func (v walkCostVal) String() string {
	if !v.ok {
		return "n/a"
	}
	return v.d.Round(time.Millisecond).String()
}

// walkCostLine renders the walk cost line. read and readD are the groups the walk read and their wall time; walkD
// is the whole walk's wall time, so the rest (clamped at 0s) is the lstat walk, the reused groups, the large files
// and the classification.
func walkCostLine(before, after walkCostSnap, read int, readD, walkD time.Duration) string {
	rest := walkD - readD
	if rest < 0 {
		rest = 0
	}
	cpuU, cpuS := walkCostSub(before.user, after.user), walkCostSub(before.sys, after.sys)
	var st [3][2]walkCostVal
	for i := range st {
		for j := range st[i] {
			st[i][j] = walkCostSub(before.psi[i][j], after.psi[i][j])
		}
	}
	return fmt.Sprintf("walk cost: %d group(s) read in %s, rest of walk %s; cpu user %s sys %s; stall some/full io %s/%s memory %s/%s cpu %s/%s",
		read, readD.Round(time.Millisecond), rest.Round(time.Millisecond), cpuU, cpuS,
		st[0][0], st[0][1], st[1][0], st[1][1], st[2][0], st[2][1])
}
