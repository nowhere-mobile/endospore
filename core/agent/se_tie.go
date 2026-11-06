package main

import (
	"bufio"
	"crypto/subtle"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

// NWP-20261006-09 -- tying a profile to this phone's secure element is OPT-IN, chosen from the profile's own settings,
// and can be undone (Chester, 2026-10-06: "the only way to tie is for user to pick that option knowing what they are
// doing with a way to revert back when they prefer"; docs/product-decisions.md, "tying a profile to a phone's secure
// element is OPT-IN"). Before this the gate tied every profile at CREATE and RECOVER, and offered it at sign-in.
//
// Three SESSION verbs, asked by the signed-in session's own chooser (ProfileActivity):
//
//	SE-STATUS\n               -> OK TIED      the vault is hardened (it opened in this session, so through this phone)
//	                          -> OK TIED PARTIAL  tied, but not every small scope is yet re-keyed to this phone (NWP-20261007-12):
//	                                              its data is still passphrase-keyed; SE-TIE finishes it
//	                          -> OK UNTIED    pass-only and this phone has a secure element: SE-TIE can tie it
//	                          -> OK NOCHIP    pass-only, but this phone has no secure element (Diaspore, or none)
//	                          -> OK OTHER     a vault with no pass slot that is not hardened (a security-key profile)
//	SE-TIE\n<passphrase>\n    -> OK | ERR-PASS | ERR-STATE | ERR-NOCHIP | ERR-NOCREDIT | ERR-WORKER-BUSY | ERR
//	SE-UNTIE\n<passphrase>\n  -> OK | ERR-PASS | ERR-STATE | ERR-NOCHIP | ERR-WORKER-BUSY | ERR
//	any                       -> ERR-NOSESSION | ERR-NOTSTORED | ERR-CALLER | NOSTORE
//
// Everything comes from the session marker -- the name, the passphrase, and the secure-element secret the gate
// computed at sign-in (ROAM-IN line 5) -- because the chip key lives in user 0, which the session cannot reach.
// The passphrase on the wire is a confirmation, compared with the session's: the change is the user's to make
// knowingly, not something an unlocked phone left on a table should allow in one tap. A wrong one is not an oracle:
// the caller is the signed-in session, which already holds the right one.
//
// Authorization: the caller must be THIS session's own user (peer uid), like ACK-TELROWS. Not the gate, and not
// another user's app.

const (
	seStatusTied    = "TIED"
	seStatusPartial = "TIED PARTIAL"
	seStatusUntied  = "UNTIED"
	seStatusNoChip  = "NOCHIP"
	seStatusOther   = "OTHER"
)

// seTiePeerUID is peerUID, a variable so a test can name the caller (net.Pipe carries no credentials).
var seTiePeerUID = peerUID

// seTieSlotWait bounds how long SE-TIE / SE-UNTIE wait behind a seal for the worker slot. It is part of handleSETie's
// connection deadline (seTieSlotWait + 10 minutes), which the chooser's read (TieCopy.READ_MS) outlasts, so a tie that
// succeeds late is still read and never reported to the user as a failure. test-tie-copy-java.sh reads this value.
var seTieSlotWait = 60 * time.Second

// errNotTiedHere: an untie asked of a vault this phone's secure element does not open.
var errNotTiedHere = errors.New("this phone's secure element does not open the profile")

// seTieCmd reports whether handleSETie serves a verb.
func seTieCmd(name string) bool {
	return name == "SE-STATUS" || name == "SE-TIE" || name == "SE-UNTIE" || name == "SE-PROGRESS"
}

func handleSETie(conn net.Conn, r *bufio.Reader, dest, verb string) {
	var confirm string
	if verb != "SE-STATUS" && verb != "SE-PROGRESS" { // the two reads carry no passphrase
		l, err := r.ReadString('\n')
		if err != nil {
			fmt.Fprint(conn, "ERR\n")
			return
		}
		confirm = strings.TrimRight(l, "\r\n")
	}
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "ERR-NOSESSION\n")
		return
	}
	if u := seTiePeerUID(conn); u < 0 || fmt.Sprint(u/100000) != uid {
		fmt.Fprint(conn, "ERR-CALLER\n")
		return
	}
	if localOnlySession(dest) {
		fmt.Fprint(conn, "ERR-NOTSTORED\n") // a throwaway or offline session has no stored vault to change
		return
	}
	if !storeConfigured() {
		fmt.Fprint(conn, "NOSTORE\n")
		return
	}
	se := seFromSession(dest)
	if verb == "SE-PROGRESS" {
		// NWP-20261008-04: how far the background re-key of the photos, files and installed apps has got.
		fmt.Fprint(conn, seProgressReply("s3", name, pass, uid, se, dest))
		return
	}
	if verb == "SE-STATUS" {
		st, err := seSessionStatus("s3", name, pass, se)
		if err != nil {
			fmt.Fprint(conn, "ERR\n")
			return
		}
		fmt.Fprintf(conn, "OK %s\n", st)
		return
	}
	if subtle.ConstantTimeCompare([]byte(confirm), []byte(pass)) != 1 {
		fmt.Fprint(conn, "ERR-PASS\n")
		return
	}
	if len(se) == 0 {
		fmt.Fprint(conn, "ERR-NOCHIP\n")
		return
	}
	// HOLD THE WORKER'S READ-WRITE SLOT for the rewrite. A seal reads the head and writes it back with the keyslots it
	// read ("keep the keyslots; just repoint the data"), so a seal that read before this rewrite and published after
	// it would silently undo the tie or the untie. Every seal runs as a worker op on this lane, one at a time, so
	// holding its slot keeps them apart. Bounded: a long seal answers busy rather than hanging the settings screen.
	// The wait, then the work. A tie now re-seals the small scopes' data and history from the store (NWP-20261007-12),
	// so it gets ten minutes, which the chooser's read (TieCopy.READ_MS) outlasts.
	conn.SetDeadline(time.Now().Add(seTieSlotWait + 10*time.Minute))
	select {
	case laneRW.slot <- struct{}{}:
		defer func() { <-laneRW.slot }()
	case <-time.After(seTieSlotWait):
		fmt.Fprint(conn, workerBusy+"\n")
		return
	}
	st, err := seSessionStatus("s3", name, pass, se)
	if err != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	var op func() error
	switch {
	case verb == "SE-TIE" && (st == seStatusUntied || st == seStatusPartial):
		op = func() error { return sessionTie("s3", name, pass, se) }
	case verb == "SE-UNTIE" && (st == seStatusTied || st == seStatusPartial):
		op = func() error { return sessionUntie("s3", name, pass, se) }
	default:
		fmt.Fprint(conn, "ERR-STATE\n") // already in the state asked for, or a vault this verb cannot change
		return
	}
	if err := daemonVaultErr(op); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] %s failed: %s\n", strings.ToLower(verb), logSafeErrText(err)) // never the name
		if errors.Is(err, errInsufficientCredit) {
			fmt.Fprint(conn, "ERR-NOCREDIT\n") // the re-sealed data is new storage, paid by the profile (2026-10-06)
			return
		}
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] %s done (NWP-20261006-09)\n", strings.ToLower(verb))
	fmt.Fprint(conn, "OK\n")
}

// seSessionStatus classifies the session's stored vault for SE-STATUS, from the head its credentials locate.
func seSessionStatus(base, name, pass string, se []byte) (string, error) {
	ref := getRef(base, headKey(base, name, pass))
	if ref == "" {
		return "", errors.New("no head")
	}
	v, isV := parseVault(getHeadBlob(base, ref))
	if !isV || v == nil {
		return "", errors.New("not a vault")
	}
	switch seStateOf(v) {
	case "HARDENED":
		// NWP-20261007-12: tied only when the small scopes are too. A scope still under the passphrase key (the tie
		// could not re-key it, or the profile was tied before scopes were) leaves its data offline-guessable.
		for _, suf := range tieSmallScopes {
			if !scopeTiedOnThisPhone(base, name+suf, pass, se) {
				return seStatusPartial, nil
			}
		}
		return seStatusTied, nil
	case "PASSONLY":
		if len(se) == 0 {
			return seStatusNoChip, nil
		}
		return seStatusUntied, nil
	}
	return seStatusOther, nil
}

// sessionTie ties the live session's stored vault to this phone's secure element: the slot change enrollSE makes (a
// `se` slot for this phone, every pass-only slot dropped, Hardened set), opened through the pass slot. It does NOT
// call enrollSE, because enrollSE publishes only the ACCOUNT head (putHeadSingle, safe at CREATE before any seal), and
// a session's own UNIT head would keep its pass slot -- the profile would stay offline-guessable through the head this
// phone opens first, which is the hazard backlog row "`enrollSE` ... leave the ACCOUNT head on an older vault"
// recorded for exactly this flow. So it publishes like a mid-session key enrol (publishSessionVault).
//
// NWP-20261007-12: and it re-keys the small scopes (#keys, #sys, #de) to the phone, so their data is no longer
// passphrase-keyed (docs/tie-scope-keys.md §8). In ONE capWrite bracket, in the order that is safe at every step:
// prepare each scope (re-sealed from the store, uploaded, unpublished), publish the vault with its tie slots and the
// index recording each new key beside the old, then switch the scope heads. A scope that cannot be re-keyed is left
// as it is and SE-STATUS reports TIED PARTIAL; a tie of a TIED PARTIAL vault runs again and re-keys what is left,
// reusing a key it already recorded so uploads dedup. A vault with no scope index yet is tied alone: the next bare
// seal mints the index, and the profile reads TIED PARTIAL until a tie finishes it.
func sessionTie(base, name, pass string, se []byte) (err error) {
	hd, v, err := readSessionVaultHead(base, name, pass)
	if err != nil {
		return err
	}
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	alreadyTied := false
	if dk == nil {
		if dk = unwrapDK(v, "se", kekSE(name, pass, se)); dk == nil {
			return errors.New("neither the passphrase nor this phone's chip opens the profile")
		}
		alreadyTied = true // TIED PARTIAL: only the scopes are left to do
	}
	idx, haveIdx := openScopeIndex(dk, v.Scopes)
	kek := kekScopes(dk)
	defer func() { // a tie that re-uploads data can run out of credit; say so instead of "store error"
		if r := recover(); r != nil {
			if e, ok := r.(error); ok && errors.Is(e, errInsufficientCredit) {
				err = e
				return
			}
			panic(r)
		}
	}()
	var rks []*scopeRekey
	vd := capWrite(name, pass, dk, func() {
		// NWP-20261009-07: the vault was read before this bracket could open; a re-key batch or another
		// publisher in between must refuse this tie, not be overwritten by it.
		if !capHoldHead(base, "tie", hd) {
			capAbort()
			return
		}
		if haveIdx {
			for _, suf := range tieSmallScopes {
				newKey := randBytes(32)
				if rec := idx[suf]; rec.Minted {
					if k, ok := unwrap(kek, rec.Wrapped); ok {
						newKey = k // resume: the key an earlier tie recorded, so its uploads dedup
					}
				}
				rk, perr := prepareScopeRekey(base, name, pass, suf, se, newKey)
				if perr != nil {
					fmt.Fprintf(os.Stderr, "[logind] se-tie: scope %s not re-keyed: %s\n", suf, logSafeErrText(perr))
					continue
				}
				rks = append(rks, rk)
			}
			v.Scopes = sealScopeIndex(dk, rekeyedIndex(idx, dk, rks))
		} else {
			fmt.Fprintf(os.Stderr, "[logind] se-tie: no scope index yet -- the vault is tied, its scopes follow at the next tie\n")
		}
		if !alreadyTied {
			tieSlots(v, name, pass, se, dk)
		}
		publishSessionVaultIn(base, name, pass, v, dk)
		publishScopeRekeys(base, name, pass, rks)
	})
	if vd.Refused() {
		return errors.New("refused at publish: the store did not accept the new head")
	}
	return nil
}

// tieSlots is the tie's slot change: this phone's `se` slot added, every pass-only slot dropped, Hardened set. Every
// other slot (recovery, fido2, another phone's `se`) is kept byte for byte. NWP-20261114-24: the new slot carries this
// phone's device label sealed under the DK (device_label.go); no other slot gains one.
func tieSlots(v *vault, name, pass string, se, dk []byte) {
	kept := []keyslot{{Kind: "se", Wrapped: wrap(kekSE(name, pass, se), dk), LabelSealed: sealSlotLabel(dk, deviceLabel())}}
	for _, s := range v.Slots {
		if s.Kind != "pass" {
			kept = append(kept, s)
		}
	}
	v.Slots = kept
	v.Hardened = true
}

// sessionUntie is sessionTie's inverse: open through THIS phone's `se` slot, drop every `se` slot (this phone's and any
// other phone's), clear Hardened, and give the passphrase its own slot back -- unless the vault has security keys,
// whose fido2 slots already open it with the passphrase plus a key (a pass-only slot there would drop the key
// requirement too, which the user did not ask for). After this, name and passphrase open the profile on any Nowhere
// phone again, and every copy of the stored vault made from now on is offline-guessable by passphrase.
//
// NWP-20261007-12: the scopes first. Each scope this phone holds tied gets a pass slot over the SAME key (nothing is
// re-sealed) and loses its `se` slots; then the vault. Both in one bracket, scope heads queued before the vault, so a
// crash between them leaves the vault tied and Untie runs again.
func sessionUntie(base, name, pass string, se []byte) error {
	hd, v, err := readSessionVaultHead(base, name, pass)
	if err != nil {
		return err
	}
	dk := unwrapDK(v, "se", kekSE(name, pass, se))
	if dk == nil {
		return errNotTiedHere
	}
	var serr error
	vd := capWrite(name, pass, dk, func() {
		if !capHoldHead(base, "untie", hd) { // NWP-20261009-07: see sessionTie
			capAbort()
			return
		}
		if serr = untieScopeHeads(base, name, pass, se, untieScopes); serr != nil {
			capAbort() // a bare return would still flush what was buffered
			return
		}
		// NWP-20261008-03: an untie also drops any background re-key in flight. Nothing was switched, so the scope
		// heads already open by passphrase; the blobs it uploaded leave the footprint and lapse.
		if idx, ok := openScopeIndex(dk, v.Scopes); ok && clearRekeyJobs(idx) {
			v.Scopes = sealScopeIndex(dk, idx)
		}
		untieSlots(v, name, pass, dk)
		publishSessionVaultIn(base, name, pass, v, dk)
	})
	if serr != nil {
		return serr
	}
	if vd.Refused() {
		return errors.New("refused at publish: the store did not accept the new head")
	}
	return nil
}

// untieScopes are the scopes an untie reaches: every scope a tie can re-key, small or large. One this phone does not
// hold tied is skipped.
var untieScopes = []string{"#keys", "#sys", "#de", "#media", "#apps"}

// untieSlots is the untie's slot change: every `se` slot dropped, Hardened cleared, and a pass-only slot back unless
// the vault already has one or has security keys (whose fido2 slots open it with the passphrase plus a key).
func untieSlots(v *vault, name, pass string, dk []byte) {
	kept := make([]keyslot, 0, len(v.Slots)+1)
	hasPass := false
	for _, s := range v.Slots {
		if s.Kind == "se" {
			continue
		}
		if s.Kind == "pass" {
			hasPass = true
		}
		kept = append(kept, s)
	}
	if !hasPass && len(listFido2Slots(v)) == 0 {
		kept = append(kept, keyslot{Kind: "pass", Wrapped: wrap(deriveKey(name, pass), dk)})
	}
	v.Slots = kept
	v.Hardened = false
}

// readSessionVault reads the vault the session's credentials locate (this unit's head, else the account head).
func readSessionVault(base, name, pass string) (*vault, error) {
	_, v, err := readSessionVaultHead(base, name, pass)
	return v, err
}

// readSessionVaultHead is readSessionVault for a caller that will republish the vault: it also returns what it
// read, for capHoldHead inside that caller's bracket (NWP-20261009-07).
func readSessionVaultHead(base, name, pass string) (vaultHead, *vault, error) {
	hd, v, isV := readVaultHead(base, name, pass)
	if hd.val == "" {
		return hd, nil, errors.New("wrong passphrase / no profile")
	}
	if !isV || v == nil {
		return hd, nil, errors.New("profile is not a vault")
	}
	return hd, v, nil
}

// publishSessionVault publishes a re-keyed vault from inside a live session the way enrollFido2 and removeFido2Key
// do: this unit's head, the recovery ref, and the account head's keyslots (syncAccountKeyslots), so a phone with no
// unit head of its own also opens with the new slots. The bracket is the session's own (capWrite): the credential
// does not move. A refusal at publish is an error, never a reported success.
func publishSessionVault(base, name, pass string, v *vault, dk []byte) error {
	if capWrite(name, pass, dk, func() { publishSessionVaultIn(base, name, pass, v, dk) }).Refused() {
		return errors.New("refused at publish: the store did not accept the new head")
	}
	return nil
}

// publishSessionVaultIn is publishSessionVault inside a caller's bracket (NWP-20261007-12), so a tie can publish the
// vault and its re-keyed scopes as one lease, in order.
func publishSessionVaultIn(base, name, pass string, v *vault, dk []byte) {
	v.Version++
	signVault(v, dk)
	vh := postBlob(base, serializeVault(v))
	putHead(base, name, pass, vh)
	putRef(base, v.RecoveryRef, vh)
	syncAccountKeyslots(base, name, pass, dk, v)
}
