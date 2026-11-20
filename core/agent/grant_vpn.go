package main

// NWP-20261210-06 (backlog "A nearly empty profile takes about 85 s from submit to home; target under 60 s", cause (6)):
// the sign-in's first always-on VPN apply rides the grant op.
//
// retryVpnup used to start at the `in` reply and send roamd a vpnup every 2 s until an OK. Every try before the
// chooser's install-existing answered NOTREADY (vpn_apply_choice: the VPN app is not installed for the user yet), and
// each one cost a wait for the worker slot and a worker start, which queued the chooser's last sign-in step, the
// grant, behind it. Now handleRoamIn registers the sign-in here (expect), handleGrantPerms claims it and flags its
// grant op (roam.req line 7 = "vpn"), roamd runs vpn_apply at the end of that grant run and leaves the answer in
// $STATE/.grantvpn.<uid>, and handleGrantPerms posts it here for retryVpnup. An OK answer ends retryVpnup with no
// vpnup run of its own; any other answer, no grant within vpnupGrantWait, or no expect falls back to today's loop.

import (
	"os"
	"path/filepath"
	"sync"
	"time"
)

// vpnupGrantWait is how long retryVpnup waits for the grant's answer before it falls back to its own loop. A var for
// the tests. Longer than the loop's ~90 s window, because the grant follows the whole provisioning.
var vpnupGrantWait = 120 * time.Second

// grantVpnFile is roamd's answer file in the RAM-tmpfs state dir (as .vpnapplied.<uid>), one per uid.
const grantVpnFile = ".grantvpn."

// grantVpnEntry is one sign-in's pending handoff.
type grantVpnEntry struct {
	claimed   bool          // a grant op was flagged for it
	delivered bool          // post ran; answer may be empty (NOTREADY)
	answer    string        // the grant's vpn_apply answer
	done      chan struct{} // closed by post
}

// grantVpnHandoff is the mutex-guarded handoff keyed by uid. The mutex is never held across a sleep, a worker run or
// a channel wait.
type grantVpnHandoff struct {
	mu sync.Mutex
	m  map[string]*grantVpnEntry
}

var grantVpn = &grantVpnHandoff{m: map[string]*grantVpnEntry{}}

// expect registers a fresh pending entry for uid, replacing an older one.
func (g *grantVpnHandoff) expect(uid string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.m[uid] = &grantVpnEntry{done: make(chan struct{})}
}

// claim is true once for a pending entry, and marks it flagged.
func (g *grantVpnHandoff) claim(uid string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	e := g.m[uid]
	if e == nil || e.claimed || e.delivered {
		return false
	}
	e.claimed = true
	return true
}

// post delivers answer to uid's pending entry, once. It never creates an entry and never blocks.
func (g *grantVpnHandoff) post(uid, answer string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	e := g.m[uid]
	if e == nil || e.delivered {
		return
	}
	e.delivered, e.answer = true, answer
	close(e.done)
}

// watch returns uid's current entry, nil when there is none.
func (g *grantVpnHandoff) watch(uid string) *grantVpnEntry {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.m[uid]
}

// ready says whether e has its answer.
func (g *grantVpnHandoff) ready(e *grantVpnEntry) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return e.delivered
}

// finish removes e when it is still uid's entry (an older waiter never removes a replacement) and returns its answer.
func (g *grantVpnHandoff) finish(uid string, e *grantVpnEntry) (string, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.m[uid] == e {
		delete(g.m, uid)
	}
	return e.answer, e.delivered
}

// wait waits up to d for uid's answer and removes the entry on any return, so a later grant is not flagged. ok is
// false when there is no entry or no answer came.
func (g *grantVpnHandoff) wait(uid string, d time.Duration) (answer string, ok bool) {
	e := g.watch(uid)
	if e == nil {
		return "", false
	}
	if d > 0 {
		t := time.NewTimer(d)
		select {
		case <-e.done:
		case <-t.C:
		}
		t.Stop()
	}
	return g.finish(uid, e)
}

// vpnupSessionGone is retryVpnup's marker check (NWP-20261113-20): the marker absent, or naming another uid, ends it;
// a damaged marker with an empty uid is still a live session.
func vpnupSessionGone(dest, uid string) bool {
	_, _, mu, st := readRoamSessionState(dest)
	return st == roamSessionAbsent || (mu != "" && mu != uid)
}

// awaitGrantVpn is retryVpnup's wait for the grant's answer: steps of vpnupSleep(2 s), at most vpnupGrantWait in
// all (counted in requested steps, not wall time), the marker re-read before each step and once more after the
// answer. stop is true when the session is gone (the caller logs the stop line). ok is false when no sign-in expected
// a grant, or no answer came in time. The entry is removed on every return.
func awaitGrantVpn(dest, uid string) (answer string, ok, stop bool) {
	e := grantVpn.watch(uid)
	if e == nil {
		return "", false, false
	}
	const step = 2 * time.Second
	for waited := time.Duration(0); !grantVpn.ready(e) && waited < vpnupGrantWait; waited += step {
		if vpnupSessionGone(dest, uid) {
			grantVpn.finish(uid, e)
			return "", false, true
		}
		vpnupSleep(step)
	}
	answer, ok = grantVpn.finish(uid, e)
	if ok && vpnupSessionGone(dest, uid) {
		return "", false, true
	}
	return answer, ok, false
}

// readGrantVpn reads and removes <dir>/.grantvpn.<uid>, roamd's answer for a flagged grant; "" when absent. A failed
// remove is ignored: the grant arm removes the file at its top. A uid that is not all digits reads nothing.
func readGrantVpn(dir, uid string) string {
	if !daySummaryUIDOK(uid) {
		return ""
	}
	p := filepath.Join(dir, grantVpnFile+uid)
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	_ = os.Remove(p)
	return vpnupReplyToken(string(b))
}
