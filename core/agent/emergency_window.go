package main

// The emergency-callback window in the login daemon (NWP-20261206-02; docs/product-decisions.md, "nineteen
// recommendations accepted (second set)", Q047). Backlog: "The emergency-callback window does not survive a user
// switch, so a PSAP callback after a login can be rejected".
//
// Telecom binds the chooser's call-control service as the FOREGROUND user, so the per-process static that marks an
// outbound emergency call (NowhereCallControlService.sLastEmergencyOutboundAt) is 0 in a roamed session's process
// when the PSAP calls back. The login daemon survives every user switch and a gate restart and loses its RAM at
// power-off, so it keeps the mark: EMERGENCY-MARK records the boot-clock time of the call, EMERGENCY-RECENT asks
// whether one went out inside the window. The chooser keeps its own static too; a hit in either counts.
//
// The only state is one CLOCK_BOOTTIME time in RAM: no number, no profile, no uid, no file. Neither verb waits on
// sessionMu or telMu, and neither logs on success: login.log rides every issue report, and the fact of an emergency
// call is the user's business.

import (
	"fmt"
	"net"
	"os"
	"sync/atomic"
)

// emergencyCallbackWindowMs is NowhereCallControlService.EMERGENCY_CALLBACK_WINDOW_MS (15 min). Keep the two equal.
const emergencyCallbackWindowMs = 15 * 60 * 1000

// emergencyMarkedAtMs is the CLOCK_BOOTTIME ms of the last EMERGENCY-MARK, 0 = none in this daemon run. RAM only: a
// daemon restart or a power-off forgets it, which Q047 accepts. A later mark replaces an earlier one.
var emergencyMarkedAtMs atomic.Int64

// Seams for tests: the caller's uid and the boot clock (CLOCK_BOOTTIME counts suspend, so a sleeping phone still
// ages the mark; bootNowMs returns 0 when the clock is unreadable).
var (
	emergencyPeerUID = peerUID
	emergencyNowMs   = bootNowMs
)

// emergencyCallerOK admits the chooser app in ANY Android user: an app uid (at least 10000) whose appId is the
// pinned chooser's. The control service runs as the foreground user, the gate or a roamed session, so unlike
// ownerCallerOK this does not require user 0. Root, system, shell, an unreadable peer (-1), an unpinned daemon (pin
// -1) and every other app are refused. pinnedChooserApp is read last, so a root peer, which skips the accept-time
// pin, never reads it while the accept loop may still be pinning (as ownerCallerOK explains).
func emergencyCallerOK(uid int) bool {
	if uid < 10000 {
		return false
	}
	app := pinnedChooserApp
	return app >= 10000 && uid%100000 == app
}

// handleEmergencyWindow serves EMERGENCY-MARK and EMERGENCY-RECENT. One line each way; nothing more is read.
//
//	EMERGENCY-MARK   -> OK | ERR clock (nothing recorded) | DENIED
//	EMERGENCY-RECENT -> YES <age_s> (marked less than 15 min ago) | NO | DENIED
//
// A caller that is not the chooser is refused before the mark or the clock is read.
func handleEmergencyWindow(conn net.Conn, name string) {
	if !emergencyCallerOK(emergencyPeerUID(conn)) {
		fmt.Fprint(os.Stderr, "[logind] emergency-window refused (caller is not the chooser)\n")
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	if name == "EMERGENCY-MARK" {
		now := emergencyNowMs()
		if now <= 0 {
			fmt.Fprint(conn, "ERR clock\n")
			return
		}
		emergencyMarkedAtMs.Store(now)
		fmt.Fprint(conn, "OK\n")
		return
	}
	at := emergencyMarkedAtMs.Load()
	if at == 0 {
		fmt.Fprint(conn, "NO\n")
		return
	}
	now := emergencyNowMs()
	if now <= 0 {
		fmt.Fprint(conn, "YES 0\n") // the safe direction: the call rings, as the Java code treats a backwards clock
		return
	}
	age := now - at
	if age < 0 {
		age = 0
	}
	if age < emergencyCallbackWindowMs {
		fmt.Fprintf(conn, "YES %d\n", age/1000)
		return
	}
	fmt.Fprint(conn, "NO\n")
}
