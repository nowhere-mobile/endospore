package main

// NWP-20261114-05: the daemon's calls of roamd's bootwake op (NWP-20261114-01). The decision (docs/product-decisions.md,
// 2026-10-24): "at sign-in, every app that asked to start at boot gets the boot broadcasts once the restore has landed".
// Its inference: an app whose data lands later, at the Auto sweep's install or an on-demand tap, is sent the
// broadcasts at its own confirmed restore. So the op runs twice over a session's life:
//   - grantTail: after GRANT-PERMS (the sign-in's last step) and its seed-home, once for every declaring package;
//   - bootWakePackage: after each later RESTORE-ODDATA that answered `OK <pkg>`, for that one package.
// roamd's replies: BOOTWAKE <sent> <declaring> | ERR-PKG | ERR-LIST (or a transport ERR-...). It skips a package whose
// data is still parked and logs counts only, never a package name; the daemon's log lines here do the same.

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// bootWakeOp runs roamd's bootwake op for user uid: pkg = one package, or "" for every declaring package. uid rides
// the name slot too, as seed-home does, so the worker's non-empty-name check passes. A var so tests replace it.
var bootWakeOp = func(dest, uid, pkg string) string {
	return triggerRoamWorkerKind(dest, "bootwake", uid, "", uid, "", "", pkg, "", nil)
}

// seedHomeOp is the seed-home worker op handleGrantPerms defers (E.5d). A var so tests replace it.
var seedHomeOp = func(dest, uid string) string {
	return triggerRoamWorker(dest, "seed-home", uid, "", uid, "", nil)
}

// grantTailDelay: why 3 s is in the NWP-20260822-27 comment in handleGrantPerms. A var so tests set it to 0.
var grantTailDelay = 3 * time.Second

// grantTail is GRANT-PERMS' deferred tail: the seed-home op, THEN the bootwake op for every declaring package.
// Sequential in one goroutine on purpose: the two ops never compete for the RW slot, and the broadcasts go after the
// restore and the grant have landed.
func grantTail(dest, uid string) {
	time.Sleep(grantTailDelay)
	verdict := strings.TrimSpace(seedHomeOp(dest, uid))
	fmt.Fprintf(os.Stderr, "[logind] seed-home user %s -> %s\n", uid, verdict)
	r := strings.TrimSpace(bootWakeOp(dest, uid, ""))
	fmt.Fprintf(os.Stderr, "[logind] bootwake user %s -> %s\n", uid, r)
}

// bootWakeArm holds the uid whose sign-in has passed GRANT-PERMS. handleGrantPerms arms it; handleRoamIn (the start of
// every roamed login) clears it. Only while it is armed for the session's uid does a RESTORE-ODDATA send its package
// the boot broadcasts. It is in memory, so an agent restart clears it too.
type bootWakeArm struct {
	mu  sync.Mutex
	uid string
}

func (g *bootWakeArm) arm(uid string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.uid = uid
}

func (g *bootWakeArm) clear() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.uid = ""
}

func (g *bootWakeArm) armed(uid string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return uid != "" && g.uid == uid
}

var bootWakeGate bootWakeArm

// bootWakeAfterRestore: RESTORE-ODDATA's trimmed reply says pkg's data landed, and the sign-in of uid has passed
// GRANT-PERMS. `OK NOSRC`, `OK LOCAL` and ERR-* do not match: no data landed.
func bootWakeAfterRestore(reply, pkg, uid string) bool {
	return reply == "OK "+pkg && bootWakeGate.armed(uid)
}

// bootWakePackage sends one restored package its boot broadcasts. The log line carries the uid only, never the
// package name.
func bootWakePackage(dest, uid, pkg string) {
	r := strings.TrimSpace(bootWakeOp(dest, uid, pkg))
	fmt.Fprintf(os.Stderr, "[logind] bootwake user %s one package -> %s\n", uid, r)
}
