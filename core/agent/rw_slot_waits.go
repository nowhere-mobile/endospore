package main

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// NWP-20261208-11: backlog row "Interactive work waits behind the Auto sweep on the one roam worker: Profile actions,
// the VPN step and app data restores queue behind fetches that hold it for up to 137 s". Its first step is a record of
// who waited behind whom on the RW lane, in counts only.
//
// Why login.log is not enough: triggerRoamWorkerKind writes a "waited ... for the slot" line and a "HELD the slot" line,
// but a gate report excludes login.log on purpose, and the "waited" line names only the waiter, never the op that held
// the slot. Both lines are also censored at 2 s on the RW lane, and log trimming can drop them. This aggregate reaches
// every issue report, the gate's included (buildIssueReportWith, status key rw_slot_waits).
//
// What it counts: every RW-lane wait in triggerRoamWorkerKind (n, and max_ms); the waits of rwSlotWaitFloor or more
// (ge5s) by "<waiting op>/<holder>", where the holder is the op that held the slot WHEN the waiter queued (on a queue
// of several waiters a later holder can also delay it); and the holds of rwSlotWaitFloor or more by op. The counts are
// since the DAEMON started, not since boot: read them against boot_id and uptime_s in the same report.
//
// Keys are daemon op codes from the code, through opClass: a short lower-case token stays, "" (a free lane) is "none",
// and anything else is "other", so an app, a profile or a uid can never reach the report. Three RW ops have a hyphen
// and so report as "other": fido2-enroll, seed-home and silence-alarm. No uid, no profile, no time stamp: safe at the
// gate. Not telemetry: a report leaves the phone only when the user sends it.
//
// Uncounted: the RW acquires outside triggerRoamWorkerKind (coldLockWaitRW in main.go, end_unsaved.go's two,
// logoff_cutoff.go, scope_rekey_job.go's two, se_tie.go). Their own waits and holds are not recorded; a waiter meets
// them as holders only when they call setRWHolder.

var rwSlotWaitFloor = 5 * time.Second // the row's CLOSES WHEN figure; a var so a test can shrink it

// rwSlotKeyCap bounds each map: a new key past it counts under the overflow key, so the report stays short.
const rwSlotKeyCap = 32

// rwSlotListMax is the most entries each list in value() shows.
const rwSlotListMax = 12

type rwSlotStat struct{ count, maxMs int64 }

type rwSlotAgg struct {
	mu    sync.Mutex
	n     int64                  // every RW wait recorded
	ge    int64                  // waits >= rwSlotWaitFloor
	maxMs int64                  // the longest wait
	pairs map[string]*rwSlotStat // "<waiter>/<holder>", waits >= the floor only
	holds map[string]*rwSlotStat // "<op>", holds >= the floor only
}

var rwSlotWaits rwSlotAgg

func rwAtFloor(ms int64) bool { return ms >= rwSlotWaitFloor.Milliseconds() }

// opClass is the report form of an op code: s when it matches ^[a-z0-9]{1,20}$, "none" for "", else "other".
func opClass(s string) string {
	if s == "" {
		return "none"
	}
	if len(s) > 20 {
		return "other"
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return "other"
		}
	}
	return s
}

// rwSlotBump counts one ms under key, or under overflow when key is new and the map is full.
func rwSlotBump(m map[string]*rwSlotStat, key, overflow string, ms int64) {
	st := m[key]
	if st == nil {
		if len(m) >= rwSlotKeyCap && key != overflow {
			key = overflow
		}
		if st = m[key]; st == nil {
			st = &rwSlotStat{}
			m[key] = st
		}
	}
	st.count++
	if ms > st.maxMs {
		st.maxMs = ms
	}
}

// wait counts one RW-lane slot wait of ms by op, which met holder when it queued. A negative value (a wall clock
// stepped back) counts as 0.
func (a *rwSlotAgg) wait(op, holder string, ms int64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if ms < 0 {
		ms = 0
	}
	a.n++
	if ms > a.maxMs {
		a.maxMs = ms
	}
	if !rwAtFloor(ms) {
		return
	}
	a.ge++
	if a.pairs == nil {
		a.pairs = map[string]*rwSlotStat{}
	}
	rwSlotBump(a.pairs, opClass(op)+"/"+opClass(holder), "other/other", ms)
}

// hold counts one RW-lane hold of ms by op, when it is at the floor or over. It does not change n, ge5s or max_ms.
func (a *rwSlotAgg) hold(op string, ms int64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if ms < 0 {
		ms = 0
	}
	if !rwAtFloor(ms) {
		return
	}
	if a.holds == nil {
		a.holds = map[string]*rwSlotStat{}
	}
	rwSlotBump(a.holds, opClass(op), "other", ms)
}

// rwSlotList is one list of value(): key:count:max, by count desc, then max desc, then key; at most rwSlotListMax
// entries; "-" when empty.
func rwSlotList(m map[string]*rwSlotStat) string {
	if len(m) == 0 {
		return "-"
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := m[keys[i]], m[keys[j]]
		if a.count != b.count {
			return a.count > b.count
		}
		if a.maxMs != b.maxMs {
			return a.maxMs > b.maxMs
		}
		return keys[i] < keys[j]
	})
	if len(keys) > rwSlotListMax {
		keys = keys[:rwSlotListMax]
	}
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s:%d:%d", k, m[k].count, m[k].maxMs)
	}
	return strings.Join(parts, ",")
}

// value is the report form. The label ge5s is fixed text; it does not follow a shrunk floor.
func (a *rwSlotAgg) value() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return fmt.Sprintf("n=%d ge5s=%d max_ms=%d waits=%s held=%s", a.n, a.ge, a.maxMs, rwSlotList(a.pairs), rwSlotList(a.holds))
}

// reset zeroes every count (the tests use it).
func (a *rwSlotAgg) reset() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.n, a.ge, a.maxMs = 0, 0, 0
	a.pairs, a.holds = nil, nil
}
