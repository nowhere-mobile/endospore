package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// NWP-20261201-03 (docs/product-decisions.md, 2026-11-07, "each profile chooses when its periodic saves run"): the
// profile's save mode, the daemon half. Three values:
//
//	"always" every periodic save runs, the DEFAULT. Absent, unreadable or unknown values all mean this.
//	"wifi"   Only on Wi-Fi: a periodic save runs only on an unmetered network (NET_CAPABILITY_NOT_METERED, so Ethernet
//	         counts and a metered hotspot does not).
//	"off"    no periodic save runs.
//
// IT GOVERNS THE PERIODIC SAVES ONLY. periodicSealDeferReason is its one consumer. Back up now (syncDeferReason alone),
// the sign-out seal and the cold lock never consult it: a sign-out saves in every mode, Back up now works in every
// mode, and a cold lock stays as it is in every mode (it runs no seal; 2026-11-09, h62 #1).
//
// WHERE IT LIVES is the seal_hold.go mechanism, for the same reasons: the choice is per profile and must roam, so the
// chooser keeps it in its own files dir in the roamed user (com.nowhere.chooser/files/nowhere-save-mode, one line); the
// daemon is MLS-refused that file, so roamd surfaces it at sign-in as "<uid> <always|wifi|off>" in the RAM state dir,
// and the Profile screen's SET-SAVE-MODE keeps it current mid-session. A change applies at the next periodic decision.
//
// THE NETWORK comes from the gate. It sends SAVE-NET-UNMETERED or SAVE-NET-METERED (metered OR no network) on every
// ~30 s slow tick while a session is live. The daemon has no network view of its own, and an old report says nothing
// about now, so a report older than saveNetFresh, or none at all, counts as metered: Only on Wi-Fi fails closed.
//
// WITHOUT THE CHOOSER HALF nothing writes nowhere-save-mode and no SAVE-NET arrives. No file means Always, so the
// periodic saves run as they did before this slice.

// saveModeOut is the state-dir file holding "<uid> <always|wifi|off>" for the live session.
const saveModeOut = "save-mode.out"

// The three modes, as they appear on the wire and in both files.
const (
	saveModeAlways = "always"
	saveModeWifi   = "wifi"
	saveModeOff    = "off"
)

// The two periodic deferral reasons a save mode can give.
const (
	saveHoldOff  = "save-mode-off"
	saveHoldWifi = "save-mode-wifi"
)

// saveNetFresh is the oldest gate report still believed. The gate sends one about every 30 s, so this allows for
// several lost ticks and still stops a Wi-Fi-only save from starting long after the phone left Wi-Fi.
const saveNetFresh = 3 * time.Minute

// saveModeValue is the mode the periodic decision applies; "" (not known) acts as Always. saveNetUnmetered and
// saveNetAt are the gate's last network report and when it arrived (zero: none yet). All three are guarded by
// pendingReapMu.
var (
	saveModeValue    string
	saveNetUnmetered bool
	saveNetAt        time.Time
)

// saveModeMu orders the two writers of the mode -- SET-SAVE-MODE and syncLoop's re-read -- so each writes file and
// memory as one step. Lock order: saveModeMu, then pendingReapMu; never the reverse.
var saveModeMu sync.Mutex

// normSaveMode returns v if it is one of the three modes, Always otherwise.
func normSaveMode(v string) string {
	switch v = strings.TrimSpace(v); v {
	case saveModeWifi, saveModeOff:
		return v
	}
	return saveModeAlways
}

// saveModeDeferReason is the whole decision: why the save mode holds this periodic cycle, or "" to go on. An age of
// exactly saveNetFresh is still fresh. A negative age is a clock that moved back, so it counts as not fresh, and the
// next gate tick corrects it. PURE.
func saveModeDeferReason(mode string, unmetered bool, netAt, now time.Time) string {
	switch mode {
	case saveModeOff:
		return saveHoldOff
	case saveModeWifi:
		if age := now.Sub(netAt); !unmetered || netAt.IsZero() || age < 0 || age > saveNetFresh {
			return saveHoldWifi
		}
	}
	return ""
}

// saveModeHoldStep decides what syncLoop logs for this cycle's deferral reason, given the hold it last reported (""
// = none): it returns the hold to remember and the line to log ("" = silent). A save-mode deferral is the user's
// choice, not a fault, so it is logged once per change and never every cycle. Any other deferral keeps prev and says
// nothing, because another guard ran first and this cycle did not reach the mode: a manual save during Off must not log
// a resume and then a new hold. PURE.
func saveModeHoldStep(prev, reason string) (string, string) {
	switch reason {
	case saveHoldOff, saveHoldWifi:
		if reason == prev {
			return prev, ""
		}
		return reason, "[logind] periodic saves held: save mode " + strings.TrimPrefix(reason, "save-mode-") + " (NWP-20261201-03)"
	case "":
		if prev != "" {
			return "", "[logind] periodic saves resume: save mode (NWP-20261201-03)"
		}
		return "", ""
	}
	return prev, ""
}

// saveHoldUpkeepAllowed reports whether a cycle the save mode held may run the upkeep at the end of a cycle. A DELETE
// or a rotation in flight has always deferred the whole cycle, upkeep included, and the hold must not change that.
func saveHoldUpkeepAllowed() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return deleteDeferLocked("") == ""
}

// saveModeFor is session user uid's mode from the state dir: Always when there is none for that uid.
func saveModeFor(dest, uid string) string {
	if uid == "" {
		return saveModeAlways
	}
	b, err := os.ReadFile(filepath.Join(dest, saveModeOut))
	if err != nil {
		return saveModeAlways
	}
	f := strings.Fields(string(b))
	if len(f) != 2 || f[0] != uid {
		return saveModeAlways // another session's value is never answered for this one
	}
	return normSaveMode(f[1])
}

// setSaveMode records session user uid's mode in the state dir (the SET-SAVE-MODE verb), by temp + rename, so a
// lock-free GET-SAVE-MODE never reads a truncated file. An unknown value is recorded as Always.
func setSaveMode(dest, uid, v string) error {
	p := filepath.Join(dest, saveModeOut)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(uid+" "+normSaveMode(v)+"\n"), 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// saveModeRefreshHook runs between refreshSaveMode's read and its apply; a seam for the ordering test.
var saveModeRefreshHook = func() {}

// refreshSaveMode re-reads session user uid's mode from the state dir and applies it, as one step under saveModeMu.
func refreshSaveMode(dest, uid string) {
	saveModeMu.Lock()
	defer saveModeMu.Unlock()
	v := saveModeFor(dest, uid)
	saveModeRefreshHook()
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	saveModeValue = v
}

// handleSetSaveMode is "SET-SAVE-MODE\n<always|wifi|off>\n<user id>\n": record the live session's mode and apply it, as
// one step under saveModeMu. It has handleSetSealHold's rules: a SET is applied only to the session of the user that
// sent it, and ERR means no live session, another session's user, or a file that cannot be written.
func handleSetSaveMode(dest, v, uid string) string {
	saveModeMu.Lock()
	defer saveModeMu.Unlock()
	nm, _, su := readRoamSession(dest)
	if nm == "" || su == "" || strings.TrimSpace(uid) != su {
		return "ERR"
	}
	if err := setSaveMode(dest, su, v); err != nil {
		dlog("SET-SAVE-MODE: %v", err)
		return "ERR"
	}
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	saveModeValue = normSaveMode(v)
	return "OK"
}

// saveModeReply answers GET-SAVE-MODE: the live session's mode, Always when there is none. A pure read.
func saveModeReply(dest string) string {
	nm, _, su := readRoamSession(dest)
	if nm == "" {
		return saveModeAlways
	}
	return saveModeFor(dest, su)
}

// recordSaveNet stores the gate's SAVE-NET report. Round(0) drops the monotonic reading, so the age in
// saveModeDeferReason is wall time: the monotonic clock stops during suspend (the NWP-20260824-10 lesson), and a report
// from before a long suspend must not look fresh after it.
func recordSaveNet(unmetered bool) {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	saveNetUnmetered, saveNetAt = unmetered, time.Now().Round(0)
}

// logSaveHold prints a line from saveModeHoldStep; "" prints nothing.
func logSaveHold(line string) {
	if line != "" {
		fmt.Fprintln(os.Stderr, line)
	}
}
