package main

// The .roamsession marker: (name, pass, uid[, se_secret]) for the LIVE roamed user, one per line, in the RAM
// tmpfs state dir -- same trick as .session: a plain file, so the sync's push-set skips it and it's gone on
// power-off. It is the daemon's ONLY record of who is signed in: the periodic seal, logoff, cold-lock,
// delete, promote and every GET-* screen read it. So it must never lie.
//
// NWP-20260904-08: it did. readRoamSession PADDED a short marker to three fields and returned an empty uid
// that was indistinguishable from a complete marker's -- no error, no log line -- while markRoamSession
// ignored the errors of BOTH its writes, so a failed write left a stale or absent marker silently. On
// frankel a delete took the uid=="" arm and rebooted, on a session whose login had demonstrably recorded
// the uid, and the periodic seal reads the same marker, so a session that loses its uid also quietly stops
// being backed up. Now a read distinguishes ABSENT / COMPLETE / DAMAGED and says which, a damaged marker
// is a logged event (shape only, once per distinct damage), and a write that fails is an error the caller
// has to answer.
//
// What "complete" means is taken from the writer, not assumed: markRoamSession is the only writer, every
// call site feeds it a non-empty name, pass and uid (the chooser refuses an empty name or passphrase before
// ROAM-IN / ROAM-IN-OFFLINE / RESUME, and the re-arm sites echo a marker that was itself complete), and it
// writes exactly four lines, the fourth (se_secret) empty for a non-hardened identity. A trailing newline
// is normal; a 3-line marker without the se line is the pre-Endospore shape and is complete; CRLF is
// tolerated. Anything else that exists is damaged.

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const roamSessionFile = ".roamsession"

// roamSessionState is what readRoamSessionState found at <dest>/.roamsession.
type roamSessionState int

const (
	roamSessionAbsent   roamSessionState = iota // no file: nobody signed in (the gate, a cold-locked or reaped session)
	roamSessionComplete                         // the shape markRoamSession writes: name, pass and uid all set (+ optional se line)
	roamSessionDamaged                          // a file exists but is NOT that shape (or cannot be read) -- logged once per distinct damage
)

func (s roamSessionState) String() string {
	switch s {
	case roamSessionAbsent:
		return "absent"
	case roamSessionComplete:
		return "complete"
	case roamSessionDamaged:
		return "damaged"
	}
	return fmt.Sprintf("roamSessionState(%d)", int(s))
}

// roamSessionRetryDelay is the pause before markRoamSession's single retry. A tmpfs write fails for reasons
// that either clear at once (EINTR, a transient EBUSY on the rename target) or never (ENOSPC, a missing dest);
// one short retry covers the first class without stalling a login on the second.
const roamSessionRetryDelay = 50 * time.Millisecond

// roamSessionWriteFile is markRoamSession's temp-file writer. A variable so a test can fail the first attempt
// and prove the retry is the one that lands the marker; production never reassigns it.
var roamSessionWriteFile = os.WriteFile

// markRoamSession writes the marker for the live roamed user. temp+rename, never WriteFile-in-place
// (NWP-20260819-01 review): REPORT-ISSUE (and GET-SESSION-TYPE / GET-STORAGE-BREAKDOWN) read this marker
// OUTSIDE sessionMu, and O_TRUNC-then-write has a real zero-length window: a one-shot reader landing in it
// sees "no session", which for a report means the scope silently flips to device AND the live name drops
// out of the redaction secrets -- a note like "alice won't sync" would POST unredacted. saveWallet's
// temp+rename is the codebase's stated bar for lock-free readers (see the GET-BILLING allowlist note).
//
// 4th line = se_secret (Endospore hardened identity; empty otherwise). RAM tmpfs only -- gone on power-off,
// exactly like the passphrase on line 2, so the SE secret is never durable on the device.
//
// Returns an error when the marker could not be written (after one retry) or when the caller asked for a
// marker that would read back as damaged (an empty name, pass or uid) -- the writer and the reader agree on
// one shape, so a marker that could never be complete is never written. On success the marker on disk is
// the new one; on failure whatever marker was there before is untouched (the temp file is removed).
func markRoamSession(dest, name, pass, uid, seSecret string) error {
	roamSessionMu.Lock()
	err := writeRoamSession(dest, name, pass, uid, seSecret, false)
	roamSessionMu.Unlock()
	if err == nil {
		resetSealStatus() // new session: outside the lock, because it takes sealMu and pendingReapMu
	}
	return err
}

// roamSessionMu makes markRoamSession and rearmRoamSession's read-decide-write atomic against each other
// (NWP-20261020-02). It is taken ONLY in those two wrappers: writeRoamSession stays the unlocked writer, since
// rearmRoamSession holds this mutex when it calls it. Lock order: roamSessionMu, then roamSessionDamageMu (the
// reader's damage log), never the other way round. No caller holds sealMu or pendingReapMu across either wrapper.
var roamSessionMu sync.Mutex

// writeRoamSession is markRoamSession with the seal-status reset optional. NWP-20261005-26: rearmRoamSession
// continues the SAME session after a failed teardown, so it must not reset: the reset wiped the FAILED verdict
// logoffSealFailed had just recorded, and GET-SYNC-STATUS then reported OK for a session that had just failed to
// seal (and SEAL-STATUS lost the cause the logging-off screen shows).
func writeRoamSession(dest, name, pass, uid, seSecret string, newSession bool) error {
	if name == "" || pass == "" || uid == "" {
		return fmt.Errorf("refusing to write an incomplete %s (name=%s, pass=%s, uid=%s)",
			roamSessionFile, setOrEmpty(name), setOrEmpty(pass), setOrEmpty(uid))
	}
	tmp := filepath.Join(dest, roamSessionFile+".tmp")
	final := filepath.Join(dest, roamSessionFile)
	body := []byte(name + "\n" + pass + "\n" + uid + "\n" + seSecret + "\n")
	var err error
	for attempt := 1; attempt <= 2; attempt++ {
		if attempt > 1 {
			time.Sleep(roamSessionRetryDelay)
		}
		if err = roamSessionWriteFile(tmp, body, 0o600); err != nil {
			continue
		}
		if err = os.Rename(tmp, final); err != nil {
			continue
		}
		if newSession {
			resetSealStatus() // new session: current as of restore, until a periodic seal actually fails
		}
		return nil
	}
	os.Remove(tmp)
	return fmt.Errorf("%s write failed after 2 attempts: %w", roamSessionFile, err)
}

// rearmRoamSession continues a session after a failed teardown (a logoff seal that failed or stalled, a rollback
// that failed) -- but only when nothing newer armed it. The caller's (name, pass, uid, seSecret) were captured when
// the teardown began, and a late arm (the verdict after a watchdog unstick can land 90 minutes on) runs after the
// user may have done anything in the session, a passphrase change included. Every teardown removes the marker at
// its claim, so a COMPLETE marker here was written after the capture: by the watchdog (identical values) or by a
// rotation (newer). Writing the captured values over it re-armed the OLD passphrase, a tombstone, and every seal
// after that pushed nothing while reporting success (NWP-20261020-02; backlog row "A PASSPHRASE CHANGE MADE IN A
// LIVE SESSION LEAVES THAT SESSION SEALING NOTHING, AND REPORTING SUCCESS"). So a complete marker is left alone and
// only an absent or damaged one is written. The read-decide-write is atomic against markRoamSession (roamSessionMu).
//
// There is nothing further the daemon can do when the write fails -- the user is still in the session -- so that
// failure is made loud together with what it costs: without the marker the periodic seal stays off and the next
// logoff finds "no session". No log line carries the name, passphrase or se secret, only their presence.
func rearmRoamSession(dest, name, pass, uid, seSecret, why string) {
	roamSessionMu.Lock()
	f, st := readRoamSessionFields(dest)
	if st == roamSessionComplete {
		roamSessionMu.Unlock()
		switch {
		case f == [4]string{name, pass, uid, seSecret}:
			// the watchdog's re-arm, or this one twice: nothing to say
		case f[0] == name && f[2] == uid:
			fmt.Fprintf(os.Stderr, "[logind] %s: %s was re-written after this teardown captured it (a passphrase change in the session) -- keeping it, user %s\n",
				why, roamSessionFile, uid)
		default:
			fmt.Fprintf(os.Stderr, "[logind] %s: %s names another session -- not overwritten\n", why, roamSessionFile)
		}
		return
	}
	err := writeRoamSession(dest, name, pass, uid, seSecret, false) // NWP-20261005-26: keep the verdict
	roamSessionMu.Unlock()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] %s WRITE FAILED: %v -- %s: user %s stays signed in UNRECORDED "+
			"(no periodic seal; logoff will find no session)\n", roamSessionFile, err, why, uid)
	}
}

// readRoamSession returns the live roamed user's (name, pass, uid), or ("", "", "") when there is no
// COMPLETE marker -- absent and damaged read the same to a caller that only wants a session to act on, and
// every such caller treats an empty name/uid as "nobody signed in" in the SAFE direction (a seal, a logoff, a
// cold-lock that finds no session does nothing). The difference between the two is not lost:
// readRoamSessionState says which, and a damaged marker is logged. The callers for which "nothing" is NOT
// the safe direction do not use this reader: the legacy-login guard, where "no session" would be followed
// by a RemoveAll of the state dir (roamSessionExists); the delete, where empty login creds would turn a
// mistyped confirm into an OK (deleteSessionCreds); and the issue-report redaction, which must still redact a
// name a damaged marker carries (readRoamSessionState).
func readRoamSession(dest string) (name, pass, uid string) {
	n, p, u, st := readRoamSessionState(dest)
	if st != roamSessionComplete {
		return "", "", ""
	}
	return n, p, u
}

// roamSessionExists reports whether ANY marker is on disk -- complete or damaged. This is the guard for a path
// that would otherwise treat "no complete session" as "nobody is signed in" and act destructively on the
// shared state tmpfs: the legacy Arc-1 login fallthrough wipes the session state dir (wipeSessionState) (DIA-20260704-33). A damaged
// marker is still a live session's marker; the user is on screen, the wallet, the fido2 stash and the seal
// caches are theirs, and a stray or version-skewed request must be refused exactly as it is for a complete
// one. STATUS and GET-SESSION-TYPE answer ACTIVE/STORED off the same existence test, so the daemon stays
// consistent with itself about whether a session is live. Goes through the parser so the damage is logged.
func roamSessionExists(dest string) bool {
	_, st := readRoamSessionFields(dest)
	return st != roamSessionAbsent
}

// deleteSessionCreds is handleDelete's read of the marker: the session's (name, pass, uid) INCLUDING the
// partial fields of a damaged one. deleteForSession disambiguates "no stored profile backs this session"
// (noop -> carry on + reap) from "real profile, mistyped confirm" (wrongpass -> NOTFOUND, nothing happens) by
// resolving the LOGIN creds; a damaged marker that still carries them (the frankel shape: uid line lost) must
// keep feeding them, or a typo on that session would reply OK for a profile that survives -- the
// DIA-20260616-50 guard, on exactly the shape this file exists to catch. A partial value is the safe
// direction here: a name/pass that resolves nothing is what a throwaway already looks like. The uid stays
// empty when it is missing, so the reboot fallback fires exactly as before.
func deleteSessionCreds(dest string) (name, pass, uid string) {
	name, pass, uid, _ = readRoamSessionState(dest)
	return name, pass, uid
}

// readRoamSessionState parses the marker and reports what it found. The fields are whatever the file holds
// (empty when a line is missing), so on roamSessionDamaged they are PARTIAL -- act on them only where a
// partial value is the safe direction. A damaged marker is logged, shape only, once per distinct damage
// (see roamSessionDamageLog): the periodic seal reads this every couple of minutes.
func readRoamSessionState(dest string) (name, pass, uid string, state roamSessionState) {
	f, st := readRoamSessionFields(dest)
	return f[0], f[1], f[2], st
}

// readRoamSessionFields is the one parser: (name, pass, uid, se_secret) + the state. Every reader of the
// marker goes through it so that "complete" means one thing.
func readRoamSessionFields(dest string) (f [4]string, state roamSessionState) {
	path := filepath.Join(dest, roamSessionFile)
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			roamSessionDamageForget()
			return f, roamSessionAbsent
		}
		// It exists and cannot be read (a directory, a permission fault): that is not "nobody signed in".
		roamSessionDamageLog(path, fmt.Sprintf("unreadable: %v", err))
		return f, roamSessionDamaged
	}
	body := strings.TrimRight(string(b), "\r\n") // a trailing newline is normal; so is an empty 4th (se) line
	var lines []string
	if body != "" {
		lines = strings.Split(body, "\n")
	}
	for i := 0; i < len(lines) && i < len(f); i++ {
		f[i] = strings.TrimSuffix(lines[i], "\r") // CRLF-tolerant on every line, not just the last
	}
	if len(lines) < 3 || len(lines) > len(f) || f[0] == "" || f[1] == "" || f[2] == "" {
		roamSessionDamageLog(path, fmt.Sprintf("%d line(s), name=%s, pass=%s, uid=%s",
			len(lines), setOrEmpty(f[0]), setOrEmpty(f[1]), setOrEmpty(f[2])))
		return f, roamSessionDamaged
	}
	roamSessionDamageForget()
	return f, roamSessionComplete
}

// setOrEmpty renders a field's PRESENCE for a log line. Never its value: the name and passphrase are the
// login secret, and the uid of a damaged marker may be anything at all (a shifted line).
func setOrEmpty(v string) string {
	if v == "" {
		return "empty"
	}
	return "set"
}

// The once-per-distinct-damage memory. The key is the damage's shape plus the file's size and mtime, so the
// same damaged file read every sync tick logs once, while a marker re-written into a (new or repeated)
// damaged shape logs again. A complete or absent marker clears it, so each stretch of damage is its own event.
var (
	roamSessionDamageMu     sync.Mutex
	roamSessionDamageLogged string
)

func roamSessionDamageLog(path, shape string) {
	key := path + "|" + shape
	if fi, err := os.Stat(path); err == nil {
		key += fmt.Sprintf("|%d|%d", fi.Size(), fi.ModTime().UnixNano())
	}
	roamSessionDamageMu.Lock()
	defer roamSessionDamageMu.Unlock()
	if key == roamSessionDamageLogged {
		return
	}
	roamSessionDamageLogged = key
	fmt.Fprintf(os.Stderr, "[logind] %s DAMAGED: %s\n", roamSessionFile, shape)
}

func roamSessionDamageForget() {
	roamSessionDamageMu.Lock()
	roamSessionDamageLogged = ""
	roamSessionDamageMu.Unlock()
}

// readRoamSessionSE returns the live session's se_secret (the .roamsession 4th line), or "" when none --
// including on a damaged marker, where nothing it holds is trusted.
func readRoamSessionSE(dest string) string {
	f, st := readRoamSessionFields(dest)
	if st != roamSessionComplete {
		return ""
	}
	return f[3]
}

// liveSession returns the currently-signed-in session's (name, pass, uid) from the .roamsession marker, or
// ("","","") when nobody is signed in (the gate, a throwaway with no stored profile, or a cold-locked
// session whose marker was cleared). Used by SEAL-TEL to deliver a bound owner's telephony live (#149).
// Same reader as everything else: a damaged marker is not a session to deliver into, so the item seals to the
// inbox for next-login delivery instead.
func liveSession(dest string) (name, pass, uid string) {
	name, pass, uid = readRoamSession(dest)
	// NWP-20261006-02: and only a user that still EXISTS. A sign-in or resume the chooser abandons can leave the
	// daemon to finish and write the marker for a user the chooser then removes; every later arrival for that profile
	// was appended live to the dead uid's mailbox with its gate notice suppressed -- record and notice both lost
	// until the next login or a reboot. With no live session the arrival seals to the inbox instead.
	if uid != "" && androidUserGone(uid) {
		liveGoneOnce.Do(func() {
			fmt.Fprintf(os.Stderr, "[logind] session marker names user %s, which no longer exists -- arrivals seal to the inbox (NWP-20261006-02)\n", uid)
		})
		return "", "", ""
	}
	return name, pass, uid
}

// androidUsersDir holds one directory per Android user; a var so tests can redirect it.
var androidUsersDir = "/data/system/users"

var liveGoneOnce sync.Once

// androidUserGone reports whether Android user uid has no /data/system/users/<uid> directory. Only a definite
// ENOENT counts: the daemon may search that dir and getattr a directory in it (s0, checked against the policy on
// lynx 2026100508), and since NWP-20261003-01 a removed user's directory stays gone. Any other error -- a denial,
// an I/O fault -- is "not known to be gone", which keeps the old behaviour rather than dropping a live session.
func androidUserGone(uid string) bool {
	if fi, err := os.Stat(androidUsersDir); err != nil || !fi.IsDir() {
		return false // no users dir to look in (not an Android /data): nothing is known, so nothing is gone
	}
	_, err := os.Stat(filepath.Join(androidUsersDir, uid))
	return errors.Is(err, fs.ErrNotExist)
}

// clearMarkerOfGoneUser removes the session marker when the Android user it names no longer exists, and reports the
// uid it cleared ("" when it kept the marker). Caller holds sessionMu, so no sign-in can rewrite the marker between
// the read and the remove.
//
// NWP-20261006-15, the open half of the backlog row "A sign-in or resume the chooser abandons can leave a stale
// `.roamsession`": the chooser gives up on a ROAM-IN after 120 s and a RESUME after 90 s, and removes that user
// without telling the daemon, which can still finish and write the marker. NWP-20261006-02 made live delivery ignore
// such a marker; every other reader still saw a session -- the periodic seal sealed on behalf of a user that is gone,
// GET-SYNC-STATUS reported it, and a resume's cold-lock checks read it -- until the next sign-in overwrote it. Called
// from the periodic seal loop (every interval) and from every reap (CLEAN-STORAGE), so the marker of an abandoned
// session goes within one sync interval. Only a definite ENOENT counts (androidUserGone): an unreadable users dir
// keeps the marker.
func clearMarkerOfGoneUser(dest string) string {
	_, _, uid := readRoamSession(dest)
	if uid == "" || !androidUserGone(uid) {
		return ""
	}
	os.Remove(filepath.Join(dest, roamSessionFile))
	forgetUiderrorsFloor(dest) // NWP-20261010-06: the user is gone, so its session -- and its floor -- is over
	resetOdWindow()            // NWP-20261011-01: and its materialise leases
	// NWP-20261016-45: and its network-location and geocoding choice. An abandoned sign-in's claim can land before the
	// chooser removes the user, and a bare removeUser reaches none of the other releases (no SWITCH, no REAP, no
	// CLEAN-STORAGE for it). Off this path (the caller holds sessionMu); roamd leaves the globals alone if another
	// session owns them by the time it runs.
	releaseLocGlobalsAsync(dest, uid, "gone")
	releaseMobileDataAsync(dest, uid, "gone") // and its mobile-data choice (docs/product-decisions.md, 2026-10-19)
	releaseDevTogglesAsync(dest, uid, "gone")
	fmt.Fprintf(os.Stderr, "[logind] session marker named user %s, which no longer exists -- cleared (NWP-20261006-15)\n", uid)
	return uid
}
