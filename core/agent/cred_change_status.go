package main

// NWP-20261208-05: the session-scope outcome record of the last passphrase change, and the issue report's
// cred_change* status keys made from it. Evidence for two docs/backlog.md section B rows: "A PASSPHRASE CHANGE MADE
// IN A LIVE SESSION LEAVES THAT SESSION SEALING NOTHING, AND REPORTING SUCCESS" (does the marker still carry the new
// passphrase, or was the old one written BACK?) and "A passphrase change silently takes the profile's SIM away:
// bindings and the sealed telephony inbox are keyed by profileRefV2(name, pass), and handleRotate updates neither"
// (what did the telephony carry move?).
//
// handleRotate (committed exits only) and recoverReply (OK only) write ONE line to <state dir>/cred-change; the
// state dir is the state tmpfs. Each change overwrites it, and forgetSessionKeys removes it at every session end,
// so no digest of a profile's refs stays on the device after its session and an older change is never reported
// as this one.
//
// Privacy: the record holds two 16-hex digests of Argon2-derived refs, never a name or passphrase. The merge
// speaks only when the signed-in profile's current ref digest equals one of them, and then only in fixed words and
// integers: never a name, ref, digest, passphrase, uid or time of day. No reply changes, so blind login is
// untouched; a refused change writes nothing and computes no extra digest.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

const credChangeFile = "cred-change"
const credChangeMaxBytes = 512

// credChangeRec is one passphrase change's outcome. Kind, Path, Marker and Keyguard are fixed words.
type credChangeRec struct {
	Kind, Path, Marker, Keyguard string
	Bind                         int
	BindErr                      bool
	Inbox                        int
	InboxErr                     bool
	Matched                      int    // -1 writes "-"
	New, Old                     string // refDigest values; Old "" writes "-"
}

// credChangeLineRE is the record's whole grammar; the writer produces only lines it accepts and the reader refuses
// every other line.
var credChangeLineRE = regexp.MustCompile(`^v=1 kind=(rotate|recover) path=(committed|partial) marker=(rekeyed|repaired|untouched|failed|none) keyguard=(rekeyed|pin|untouched) bind=([0-9]{1,9}) binderr=([01]) inbox=([0-9]{1,9}) inboxerr=([01]) matched=([0-9]{1,9}|-) new=([0-9a-f]{16}) old=([0-9a-f]{16}|-)$`)

// refDigest is the first 16 hex of sha256(ref), "" for "". ⚠ Apply it ONLY to a profileRefV2 value (the
// Argon2-derived ref), NEVER to a name or a passphrase: a fast hash of those is #80's offline oracle.
func refDigest(ref string) string {
	if ref == "" {
		return ""
	}
	h := sha256.Sum256([]byte(ref))
	return hex.EncodeToString(h[:])[:16]
}

// b01 is 1 for true, 0 for false.
func b01(b bool) int {
	if b {
		return 1
	}
	return 0
}

// line is the record's one line.
func (r credChangeRec) line() string {
	matched := "-"
	if r.Matched >= 0 {
		matched = strconv.Itoa(r.Matched)
	}
	old := r.Old
	if old == "" {
		old = "-"
	}
	return fmt.Sprintf("v=1 kind=%s path=%s marker=%s keyguard=%s bind=%d binderr=%d inbox=%d inboxerr=%d matched=%s new=%s old=%s",
		r.Kind, r.Path, r.Marker, r.Keyguard, r.Bind, b01(r.BindErr), r.Inbox, b01(r.InboxErr), matched, r.New, old)
}

// writeCredChange writes the record to dir, 0600, temp + rename. Best effort: an error is one stderr line with the
// error class only, never a name, ref or path.
func writeCredChange(dir string, r credChangeRec) {
	if err := writeFileAtomic(filepath.Join(dir, credChangeFile), r.line()+"\n"); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] cred-change record not written: %s (NWP-20261208-05)\n", errCode(err))
	}
}

// removeCredChange deletes the record (and a temp a failed write left) from the login state dir. forgetSessionKeys
// calls it at every session end.
func removeCredChange() {
	p := filepath.Join(loginStateDir(), credChangeFile)
	os.Remove(p)
	os.Remove(p + ".tmp")
}

// credMarkerWord is what a committed rotation did to the session marker, when its write succeeded.
func credMarkerWord(live, staleMarker bool) string {
	switch {
	case live:
		return "rekeyed"
	case staleMarker:
		return "repaired"
	}
	return "untouched"
}

// credKeyguardWord is what a committed rotation did to the warm keyguard.
func credKeyguardWord(live, rekeyed bool, dest string) string {
	switch {
	case rekeyed:
		return "rekeyed"
	case live && sessionPIN(dest) != "":
		return "pin"
	}
	return "untouched"
}

// rotateCredChange is a committed rotation's record. Both refs are in the KDF cache after the commit, so the two
// digests cost no extra Argon2 pass.
func rotateCredChange(name, oldpass, newpass, path, marker, keyguard string, tc telCarry) credChangeRec {
	return credChangeRec{
		Kind: "rotate", Path: path, Marker: marker, Keyguard: keyguard,
		Bind: tc.Bind, BindErr: tc.BindErr, Inbox: tc.Inbox, InboxErr: tc.InboxErr, Matched: -1,
		New: refDigest(profileRefV2(name, newpass)), Old: refDigest(profileRefV2(name, oldpass)),
	}
}

// The hand-off from recoverVault (which runs the carry once the recovery committed) to recoverReply (which writes
// the record on OK). The CLI `recover` sets it too and nothing reads it there: it dies with the process.
var (
	recoverCarryMu  sync.Mutex
	recoverCarryOut *telCarry
)

func handOutRecoverCarry(tc telCarry) {
	recoverCarryMu.Lock()
	recoverCarryOut = &tc
	recoverCarryMu.Unlock()
}

// takeRecoverCarry returns the carry recoverVault handed out and clears it.
func takeRecoverCarry() (telCarry, bool) {
	recoverCarryMu.Lock()
	defer recoverCarryMu.Unlock()
	if recoverCarryOut == nil {
		return telCarry{}, false
	}
	tc := *recoverCarryOut
	recoverCarryOut = nil
	return tc, true
}

// writeRecoverCredChange writes a committed recovery's record. The old passphrase is lost and never used: the old
// digest is of the one bound owner that held the vault's telephony key, and only when exactly one did.
func writeRecoverCredChange(name, newpass string) {
	tc, ok := takeRecoverCarry()
	if !ok {
		return
	}
	old := ""
	if tc.Matched == 1 {
		old = refDigest(tc.OldRef)
	}
	writeCredChange(loginStateDir(), credChangeRec{
		Kind: "recover", Path: "committed", Marker: "none", Keyguard: "untouched",
		Bind: tc.Bind, BindErr: tc.BindErr, Inbox: tc.Inbox, InboxErr: tc.InboxErr, Matched: tc.Matched,
		New: refDigest(profileRefV2(name, newpass)), Old: old,
	})
}

// mergeCredChange adds the cred_change* keys to an in-session issue report, for the profile now signed in only.
// A caller-sent cred_change* key never survives. Gate and device scope add nothing; an unreadable record adds
// cred_change=unreadable alone; a record that is not the signed-in profile's adds nothing.
func mergeCredChange(status map[string]string, dest string, deviceScope bool) {
	for k := range status { // a nil map ranges zero times
		if strings.HasPrefix(k, "cred_change") {
			delete(status, k)
		}
	}
	if deviceScope || status == nil {
		return
	}
	f, err := os.Open(filepath.Join(dest, credChangeFile))
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	if err != nil {
		status["cred_change"] = "unreadable"
		return
	}
	b, err := io.ReadAll(io.LimitReader(f, credChangeMaxBytes+1))
	f.Close()
	if err != nil || len(b) > credChangeMaxBytes {
		status["cred_change"] = "unreadable"
		return
	}
	m := credChangeLineRE.FindStringSubmatch(strings.TrimSuffix(string(b), "\n"))
	if m == nil {
		status["cred_change"] = "unreadable"
		return
	}
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		return
	}
	// Only now, with a valid record: one Argon2 pass after a cold resume.
	curRef := profileRefV2(name, pass)
	cur := refDigest(curRef)
	rnew, rold := m[10], m[11]
	nowWord := ""
	switch {
	case cur == rnew:
		nowWord = "matches"
	case rold != "-" && cur == rold:
		nowWord = "reverted"
	}
	if nowWord == "" {
		return
	}
	telMu.Lock()
	bs := readBindings()
	telMu.Unlock()
	owned := 0
	for _, bl := range bs {
		for _, o := range bl.Owners {
			if o.ProfileRef == curRef {
				owned++
				break
			}
		}
	}
	status["cred_change"] = m[1]
	status["cred_change_path"] = m[2]
	status["cred_change_marker"] = m[3]
	status["cred_change_keyguard"] = m[4]
	status["cred_change_marker_now"] = nowWord
	status["cred_change_sim_bindings"] = m[5]
	status["cred_change_sim_bindings_err"] = m[6]
	status["cred_change_sim_inbox"] = m[7]
	status["cred_change_sim_inbox_err"] = m[8]
	if m[1] == "recover" {
		status["cred_change_sim_matched"] = m[9]
	}
	status["cred_change_sim_owned_now"] = strconv.Itoa(owned)
}
