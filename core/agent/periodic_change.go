package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// The periodic save's change test (NWP-20261202-10; docs/product-decisions.md, 2026-11-09 item 4, as amended
// 2026-11-10). syncLoop used to run the "out" op every cycle a defer did not stop, so an idle profile saved for 8-10
// minutes every 11-12 minutes. Now a cycle saves only when one of these says so, checked in this order:
//
//	nobase     no save has landed this session (nothing to compare with)
//	floor      periodicChangeFloor has passed since the last landed save (bounds a writer the test misses)
//	dirty      a shrink (EXPECT-SHRINK*) or a change of the wallet file marked the session
//	probe-err  the change walk failed or did not answer one JSON object
//	old-agent  the walk answered without "mode":"change" (until M07aa's change mode is on the image: every cycle)
//	changed    the walk counted a change, or a deletion it cannot place
//
// and skips only on "nochange". Every doubt saves. The interval itself is not set here (M08).

// periodicChangeFloor is the longest a session goes without a periodic save while it is live.
const periodicChangeFloor = 60 * time.Minute

// periodicDirty is the session's change mark: set by the three EXPECT-SHRINK handlers on OK, by periodicNoteWallet
// when the wallet file changed, and by periodicSealVerdict when a periodic seal did not land. syncLoop clears it
// right after a true announce, so a mark set while that seal runs survives to the next cycle.
var periodicDirty atomic.Bool

// periodicNoChangeSkips counts the periodic cycles the change test skipped this session.
var periodicNoChangeSkips atomic.Int64

// periodicWalletStamp is the wallet file's stat taken right after the last periodic seal that landed.
var periodicWalletStamp struct {
	mu      sync.Mutex
	set     bool
	absent  bool
	size    int64
	mtimeNs int64
}

// periodicChangeProbe runs the change walk for the live session and returns its reply; tests replace it.
var periodicChangeProbe = defaultPeriodicChangeProbe

// periodicChangeReply is the change walk's reply (M07aa's contract). Pointers make a missing count visible.
type periodicChangeReply struct {
	Mode           string   `json:"mode"`
	ChangedFiles   *int64   `json:"changedFiles"`
	DeferredFiles  *int64   `json:"deferredChangedFiles"`
	DeletedFiles   *int64   `json:"deletedFiles"`
	ChangedDirs    *int64   `json:"changedDirs"`
	StateChanged   *int64   `json:"stateChanged"`
	AppsChanged    *int64   `json:"appsChanged"`
	Blind          *int64   `json:"blind"`
	DeletedUnknown []string `json:"deletedUnknown"`
}

// counts lists the seven counts in a fixed order (files, dirs, deferred, deleted, state, apps, blind).
func (r periodicChangeReply) counts() []*int64 {
	return []*int64{r.ChangedFiles, r.ChangedDirs, r.DeferredFiles, r.DeletedFiles, r.StateChanged, r.AppsChanged, r.Blind}
}

// parsePeriodicChange reads reply as exactly one JSON object; false when it is not one.
func parsePeriodicChange(reply string) (periodicChangeReply, bool) {
	var r periodicChangeReply
	s := strings.TrimSpace(reply)
	if !strings.HasPrefix(s, "{") || json.Unmarshal([]byte(s), &r) != nil {
		return periodicChangeReply{}, false
	}
	return r, true
}

// periodicSaveDueBase is the part of periodicSaveDue that needs no probe: "" when it does not decide.
func periodicSaveDueBase(now time.Time, lastLanded int64, dirty bool) string {
	if lastLanded == 0 {
		return "nobase"
	}
	if now.Unix()-lastLanded >= int64(periodicChangeFloor/time.Second) {
		return "floor"
	}
	if dirty {
		return "dirty"
	}
	return ""
}

// periodicSaveDue decides whether a periodic cycle saves, and says why in one fixed word (the order is in the file
// comment above). reply and err are the change walk's; they are read only when the first three rules do not decide.
func periodicSaveDue(now time.Time, lastLanded int64, dirty bool, reply string, err error) (due bool, why string) {
	if w := periodicSaveDueBase(now, lastLanded, dirty); w != "" {
		return true, w
	}
	if err != nil {
		return true, "probe-err"
	}
	r, ok := parsePeriodicChange(reply)
	if !ok {
		return true, "probe-err"
	}
	if r.Mode != "change" {
		return true, "old-agent"
	}
	for _, c := range r.counts() {
		if c == nil || *c < 0 {
			return true, "probe-err" // a count the walk did not give, or one it cannot have: doubt saves
		}
	}
	for _, c := range r.counts() {
		if *c > 0 {
			return true, "changed"
		}
	}
	if len(r.DeletedUnknown) > 0 {
		return true, "changed"
	}
	return false, "nochange"
}

// periodicGate is syncLoop's change test for the live session: due, the why word, and whether the probe ran. It logs
// the walk's counts when the probe ran and the cycle saves; never the reply, the name or the uid.
func periodicGate(dest, name, pass, uid string) (due bool, why string, probed bool) {
	last, dirty := lastLandedSealStartedAt.Load(), periodicDirty.Load()
	if w := periodicSaveDueBase(time.Now(), last, dirty); w != "" {
		return true, w, false
	}
	reply, err := periodicChangeProbe(dest, name, pass, uid, last)
	due, why = periodicSaveDue(time.Now(), last, dirty, reply, err)
	if due {
		var n [7]int64 // zeros when the reply did not parse
		unknown := 0
		if r, ok := parsePeriodicChange(reply); ok {
			for i, c := range r.counts() {
				if c != nil {
					n[i] = *c
				}
			}
			unknown = len(r.DeletedUnknown)
		}
		fmt.Fprintf(os.Stderr, "[logind] periodic change test: %s (files=%d dirs=%d deferred=%d deleted=%d unknown=%d state=%d apps=%d blind=%d)\n",
			why, n[0], n[1], n[2], n[3], unknown, n[4], n[5], n[6])
	}
	return due, why, true
}

// defaultPeriodicChangeProbe writes the walk's index (reused only when it was written at or after the last landed
// announce) and asks the worker's change walk on the RO lane for what changed since that announce.
func defaultPeriodicChangeProbe(dest, name, pass, uid string, since int64) (string, error) {
	se := seFromSession(dest)
	if err := refreshSealDeltaIdx(dest, name, pass, se, func(at time.Time) bool { return !at.Before(time.Unix(since, 0)) }); err != nil {
		return "", err
	}
	return strings.TrimSpace(triggerRoamWorkerKind(dest, "sealdelta", name, "", uid, "", "", fmt.Sprintf("%d change", since), "", nil)), nil
}

// periodicWalletStat reads the wallet file's stat. ok is false when the stat failed for a reason other than absence.
func periodicWalletStat(dest string) (absent bool, size, mtimeNs int64, ok bool) {
	fi, err := os.Stat(walletPathFor(dest))
	if errors.Is(err, fs.ErrNotExist) {
		return true, 0, 0, true
	}
	if err != nil {
		return false, 0, 0, false
	}
	return false, fi.Size(), fi.ModTime().UnixNano(), true
}

// periodicNoteWallet marks the session when the wallet file differs from the stamp of the last landed periodic seal:
// a purchase, a redeem, a claim or a renewal since then. No stamp yet, or a stat that failed, also marks it.
func periodicNoteWallet(dest string) {
	absent, size, mtimeNs, ok := periodicWalletStat(dest)
	s := &periodicWalletStamp
	s.mu.Lock()
	same := ok && s.set && s.absent == absent && s.size == size && s.mtimeNs == mtimeNs
	s.mu.Unlock()
	if !same {
		periodicDirty.Store(true)
	}
}

// periodicSealVerdict takes the wallet stamp after a periodic seal that landed (before that cycle's maybePayRent, so
// a renewal after it marks the next cycle), and marks the session again after one that did not: a shrink mark the
// announce cleared must not be lost to a seal that failed.
func periodicSealVerdict(dest, out string) {
	if !strings.HasPrefix(sealVerb(out), "OK") {
		periodicDirty.Store(true)
		return
	}
	absent, size, mtimeNs, ok := periodicWalletStat(dest)
	s := &periodicWalletStamp
	s.mu.Lock()
	s.set, s.absent, s.size, s.mtimeNs = ok, absent, size, mtimeNs
	s.mu.Unlock()
}

// resetPeriodicChange clears the change mark, the wallet stamp and the skip count for a new sign-in.
func resetPeriodicChange() {
	periodicDirty.Store(false)
	periodicNoChangeSkips.Store(0)
	s := &periodicWalletStamp
	s.mu.Lock()
	s.set, s.absent, s.size, s.mtimeNs = false, false, 0, 0
	s.mu.Unlock()
}
