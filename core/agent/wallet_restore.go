package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- a sign-in whose wallet read fails publishes no wallet (NWP-20261013-20) ----
//
// At roam-in the departed wallet is removed and the arriving profile's is read back from the store. getRef/getBlob
// panic on a failed read, and the roam-in ran the restore in a bare recover(), so a failed read passed for "no wallet
// has roamed": the session ran with no wallet file, and a claim drained into it wrote a wallet holding ONLY the new
// tokens, which the next fold published over the stored one. Blind tokens are bearer instruments the gateway cannot
// re-issue, so the stored wallet's unspent tokens were then gone.
//
// THE INVARIANT: no publish may ever replace the stored wallet with a copy missing tokens the store holds.
//
// THE RULE, FAIL-CLOSED BY CONSTRUCTION: a wallet publish made for generation G (THE GENERATION, wallet_lock.go) is
// refused UNLESS G carries a RESTORE PROOF -- a per-generation file written only when G's restore LANDED, or when a
// strict read of the store proved there is no wallet to restore (a definite 404 on every rung of the head's ladder;
// never a 403, a transport error, a damaged blob or one that does not open). No proof is the default, so every
// generation nobody vouched for is refused: the generations removeWallet's two bumps mint before the arriving
// restore runs, an unreadable .gen (walletGenUnreadable), a sign-in whose read failed, a throwaway. Each publisher
// asks with the generation IT captured -- capFlush's walletGen (the fold) and walletBasisGen (putWalletHead),
// payRentGen's gen (through sealWalletValueDurable), sealWalletDurable's and sealWallet's own read -- never "is there
// a proof now", so a departed session's late publish is judged by its own sign-in and a later session's failed read
// cannot block the departed one's last word.
//
// A publisher that takes its COPY of the wallet in one place and publishes it in another -- payRent's by-value
// publish, a durable seal, a create's staged claim -- is judged by the proof as it stood WHEN THE COPY WAS TAKEN, read
// under the wallet lock with the copy, and by its generation's proof again when it publishes (pass 5). A proof vouches
// only for copies taken after it: a retry that lands while such a publish is in flight proves the generation, but the
// copy in flight predates the merge and lacks the stored tokens (a fix review reproduced it: stored 10 -> 1).
//
// The proof lives on disk beside wallet.json (wallet.json.landed-<hash of G>), so the seal WORKER, a separate process
// whose capFlush folds the wallet, sees it, and a login daemon that restarts mid-session still sees it. There is no
// other copy: a proof the disk refuses is FORFEITED, and the restore that wanted it is undone under the wallet lock,
// so the session holds none of the stored tokens it could not prove. It is then a session whose read failed -- it
// publishes nothing, a later retry may still land, and its sign-out warns when it holds credit. A landing is staged so
// that nothing after the file lands allocates (stageWalletLanding): proving it is one rename, undoing it another, and
// an undo touches the file only when the landing changed it (a retry that proved there is no stored wallet changes
// none, so its forfeit leaves the session's own claimed tokens where they are).
// ⚠ ONE WINDOW STAYS: a daemon that dies between the file's rename and the proof's (two adjacent renames), or a proof
// rename that fails followed by an undo rename that fails too, leaves the session holding the stored wallet with no
// proof. It still publishes nothing, but a later retry merges the stored tokens in again, so one it spent meanwhile
// comes back: the next fold publishes that dead nonce, and every funded lease that presents it is refused 409 until
// something prunes spent nonces (the NWP-20260915-27 class). The failed renames are logged; the death is not.
//
// What it does NOT do: stop spending or leasing. The session's wallet file is used as before; only its PUBLISH is
// held back. Credit claimed in such a session is therefore NOT durable until a retried read lands
// (retryWalletRestore, run by "Add credits", by the periodic seal, by a sign-out (LOGOUT) and by
// END-UNSAVED / RESTART-UNSAVED); a session that ends without one loses it, and says so (docs/product-decisions.md,
// 2026-10-15) -- on the gate, on its own ending screen, or, for a parked session a sign-in supersedes, in the log
// only. Every retry is handed the generation its caller captured BEFORE it read the session or the store, and
// refuses unless the wallet is still at that generation both before its read and under the lock: a retry that read
// session A's credentials must never merge A's stored wallet into the file of the session that replaced A.

var errWalletNotRestored = errors.New("this session's wallet was not restored; it will not publish one")

// errWalletNoSlot is a wallet publish whose key resolution read a vault head that no slot this phone holds opens:
// the sign-in was changed on another phone, or this phone lost its unlock. handleEndUnsaved reads it to end a
// stranded session without the publish (#19 of 2026-10-22, NWP-20261114-06).
var errWalletNoSlot = errors.New("no keyslot opens this profile's vault")

// errWalletProofNotWritten is a restore whose proof the disk refused: forfeited and undone, so not restored.
var errWalletProofNotWritten = errors.New("the wallet restore proof could not be written")

// walletLandedProofHead starts every proof file; the generation follows it, so a proof is read back as THIS
// generation's and an empty or truncated file proves nothing.
const walletLandedProofHead = "nowhere-wallet-restore-landed\n"

// walletRestoreLandedPath is generation gen's restore proof. Beside wallet.json and named wallet.json.*, so
// wipeSessionState leaves it, and NOT removed by removeWallet: it must outlive the next sign-in, because a departed
// session's publisher still asks about its own generation after that. One small file per landed sign-in, in the state
// tmpfs, gone at power-off. The generation is hashed into the name so any .gen content makes a plain file name.
func walletRestoreLandedPath(walletPath, gen string) string {
	sum := sha256.Sum256([]byte("nowhere-wallet-gen\x00" + gen))
	return walletPath + ".landed-" + hex.EncodeToString(sum[:8])
}

// walletRestoreLanded reports that generation gen's restore landed (or that there was provably nothing to restore),
// so a wallet published for gen carries every token the store held. Anything short of a readable proof naming gen --
// no file, a file that cannot be read, a directory, a proof of another generation -- is false.
func walletRestoreLanded(walletPath, gen string) bool {
	if gen == walletGenUnreadable {
		return false
	}
	b, err := os.ReadFile(walletRestoreLandedPath(walletPath, gen))
	return err == nil && string(b) == walletLandedProofHead+gen
}

// walletNotRestored is the refusal every wallet publisher asks: true unless gen's restore proof stands.
func walletNotRestored(walletPath, gen string) bool { return !walletRestoreLanded(walletPath, gen) }

// walletAtGeneration reports that walletPath's generation reads back as gen, a readable one: the check a retry makes
// against the generation its caller captured, before its read and again under the lock.
func walletAtGeneration(walletPath, gen string) bool {
	g, err := walletGenerationErr(walletPath)
	return err == nil && gen != walletGenUnreadable && g == gen
}

// markWalletRestoreLanded writes gen's restore proof (temp+rename) for a generation whose file it does not change --
// a proven absence (pullWalletStrict, proveNoStoredWallet) -- or answers errWalletProofNotWritten and holds NO proof
// anywhere: the generation then publishes nothing. A restore that changes the file is staged instead
// (stageWalletLanding). Never for an unreadable generation, which nothing may publish for. Logged loudly, because the
// session it costs loses the credit it claims unless a later retry lands.
func markWalletRestoreLanded(walletPath, gen string) error {
	if err := walletProofGenOK(gen); err != nil {
		return err
	}
	p := walletRestoreLandedPath(walletPath, gen)
	tmp := p + ".tmp"
	err := os.WriteFile(tmp, []byte(walletLandedProofHead+gen), 0o600)
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		os.Remove(tmp)
		return walletProofForfeited(err)
	}
	return nil
}

// walletProofGenOK refuses an unreadable generation, which no proof is ever written for.
func walletProofGenOK(gen string) error {
	if gen != walletGenUnreadable {
		return nil
	}
	fmt.Fprintf(os.Stderr, "[agent] wallet: no restore proof for an unreadable generation -- this session publishes "+
		"no wallet (NWP-20261013-20)\n")
	return fmt.Errorf("%w: the wallet generation cannot be read", errWalletProofNotWritten)
}

// walletProofForfeited is the one loud line for a proof the disk refused, and its error.
func walletProofForfeited(err error) error {
	fmt.Fprintf(os.Stderr, "[agent] wallet: WARNING the restore proof could NOT be written (%v) -- FORFEITED: no proof is "+
		"held anywhere, nothing of the restore is kept, and this session publishes no wallet; credit it claims is lost "+
		"at sign-out unless a later retry lands (NWP-20261013-20)\n", err)
	return fmt.Errorf("%w: %v", errWalletProofNotWritten, err)
}

// forfeitWalletRestoreLanded withdraws gen's restore proof (removeWallet, when the generation could not be moved on).
func forfeitWalletRestoreLanded(walletPath, gen string) {
	p := walletRestoreLandedPath(walletPath, gen)
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "[agent] wallet: a restore proof could not be withdrawn (%v) (NWP-20261013-20)\n", err)
	}
}

// panicAsErr turns a recovered value into an error.
func panicAsErr(r any) error {
	if e, ok := r.(error); ok {
		return e
	}
	return fmt.Errorf("%v", r)
}

// getRefBytesStrict is getRefBytes for a read that must never take a failure for absence: (b, true) present,
// (nil, false) a DEFINITE not-found, and a panic (after the retries, as getRef) for everything else -- a transport
// error, a 5xx, and a 403, which capGet would read as a hide-existence absence (capGetStrict).
func getRefBytesStrict(base, ref string) ([]byte, bool) {
	if isS3(base) && capMode() {
		return capGetStrict("ref/" + ref)
	}
	if base == "disco" || isS3(base) {
		return getRefBytes(base, ref) // s3Get: only NoSuchKey / 404 is absence, anything else fails loudly
	}
	resp, err := http.Get(base + "/ref/" + ref)
	checkRead(err)
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, false
	}
	if resp.StatusCode != http.StatusOK {
		fail(fmt.Sprintf("GET ref -> status %d (strict read)", resp.StatusCode))
	}
	b, rerr := io.ReadAll(resp.Body)
	checkRead(rerr)
	return b, true
}

// refProbeStrict is headRefWith's probe for the wallet's strict read: getRefBytesStrict, value always in hand.
func refProbeStrict(base, ref string) (exists bool, val string, haveVal bool) {
	b, ok := getRefBytesStrict(base, ref)
	if !ok {
		return false, "", true
	}
	return true, strings.TrimSpace(string(b)), true
}

// errWalletBlobDamaged is a stored wallet blob whose bytes do not hash to the key they were read from.
var errWalletBlobDamaged = errors.New("the stored wallet blob does not hash to its key (damaged in the store or in transit)")

// errWalletUnopenable and errWalletUnparsable are the other two damage cases of a stored wallet whose bytes did hash
// to their key: it does not open with the profile's key, or it opens and is not a wallet (Q153).
var errWalletUnopenable = errors.New("the stored wallet does not open with this profile's key")
var errWalletUnparsable = errors.New("the stored wallet does not parse")

// walletDamage reports that a strict read failed because the stored wallet itself is damaged (Q153's two cases: the
// blob does not hash to its key; it does and will not open or parse) -- never a 403, a 5xx, a transport error, a
// missing blob, a stored wallet with no key to open it, or any other recovered panic.
func walletDamage(err error) bool {
	return errors.Is(err, errWalletBlobDamaged) ||
		errors.Is(err, errWalletUnopenable) ||
		errors.Is(err, errWalletUnparsable)
}

// walletBlobVerified reads the wallet blob at head and checks it is the content that key names (the store is
// content-addressed: postBlob keys a blob by the SHA-256 of its bytes). A mismatch is read once more and is then a
// FAILED read, never a wallet and never absence.
func walletBlobVerified(base, head string) ([]byte, error) {
	for attempt := 0; attempt < 2; attempt++ {
		b := getBlob(base, head)
		sum := sha256.Sum256(b)
		if hex.EncodeToString(sum[:]) == head {
			return b, nil
		}
	}
	return nil, errWalletBlobDamaged
}

// readStoredWalletStrict is the restore's read of (name, pass)'s stored wallet, and it never takes a failure for
// absence (blind login is not involved: the wallet head is keyed by name AND passphrase, and this runs only for a
// session whose data head resolved):
//
//	(w, pt, nil)     the stored wallet, and its plaintext as stored
//	(nil, nil, nil)  PROVABLY none: every rung of the head's ladder answered a definite not-found, or the head is a
//	                 delete tombstone
//	(nil, nil, err)  anything else: a read that failed, a 403, a blob whose bytes do not hash to its key, no key to
//	                 open it with (dk nil), a blob that does not unseal or does not parse. The damage cases are typed
//	                 (errWalletBlobDamaged, errWalletUnopenable, errWalletUnparsable: walletDamage); dk nil and every
//	                 recovered panic are not
func readStoredWalletStrict(base, name, pass string, dk []byte) (w *Wallet, pt []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			w, pt, err = nil, nil, panicAsErr(r)
		}
	}()
	_, head, _ := headRefWith(base, name+"#wallet", pass, refProbeStrict)
	if head == "" {
		return nil, nil, nil
	}
	blob, err := walletBlobVerified(base, head)
	if err != nil {
		return nil, nil, err
	}
	if dk == nil {
		return nil, nil, errors.New("there is a stored wallet and no key to open it with")
	}
	func() {
		defer func() { recover() }()
		pt = unseal(dk, blob)
	}()
	if len(pt) == 0 {
		return nil, nil, errWalletUnopenable
	}
	var got Wallet
	if json.Unmarshal(pt, &got) != nil {
		return nil, nil, errWalletUnparsable
	}
	return &got, pt, nil
}

// readStoredWalletForPublish is the cap-mode fold's read of the stored wallet (storedWalletForPublish). Tests replace it.
var readStoredWalletForPublish = readStoredWalletStrict

// storedWalletForPublish is the stored wallet the cap-mode fold merges into, and whether the fold may write the
// #wallet head at all (dn-1031 #1, decided 2026-10-21, option (b)): while the stored copy cannot be read the head is
// not written -- the data still seals -- and the wallet publishes at the next save that can read it.
//
//	(w, true)    the stored wallet
//	(nil, true)  provably none, or a DAMAGED copy (walletDamage): today's publish of the local set, which the restore-
//	             proof gate and REPAIR-WALLET (Q153) govern
//	(nil, false) any other failure: a transport error, a 403, a 5xx, a timeout, no key to open it with
func storedWalletForPublish(base, name, pass string, dk []byte) (*Wallet, bool) {
	w, _, err := readStoredWalletForPublish(base, name, pass, dk)
	if err == nil {
		return w, true
	}
	if walletDamage(err) {
		return nil, true
	}
	return nil, false
}

// writeRestoredWallet puts the restored plaintext in place as generation gen's wallet file and writes gen's restore
// proof, both under the wallet lock when it can be had within walletSignInWait (a holder still there after it is the
// departed session's, and it checks the generation removeWallet moved on and does not save). A generation that moved
// meanwhile is not written to: the file is somebody else's. The landing is staged (stageWalletLanding), so a disk
// that refuses a write refuses it before the file is touched, and a proof that still cannot be renamed into place
// UNDOES the restore -- the kept copy renamed back, or the file removed when there was none -- so the session never
// holds stored tokens it has no proof for (bar the window the header of this file names).
//
// h46 #1 (NWP-20261116-03): the roam-in's landing now runs in the sign-in's late job, after the reply, with the user
// already in the session (mayWrite is its guard; nil for the CLI's wallet-pull and the tests). So it can meet a proof
// a locked retry wrote at this generation -- it then does nothing -- and a file the session wrote at it (a claim) --
// it then merges that file (mergeLateRestore) under the lock, and never without the lock.
func writeRestoredWallet(walletPath, gen string, pt []byte, mayWrite func() bool) error {
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	if !walletAtGeneration(walletPath, gen) {
		return errWalletChangedHands
	}
	// A standing proof FIRST: a locked retry (Add credits through sealClaimedWallet, the periodic seal, a sign-out's
	// retry) already landed this generation, so nothing is left to write and neither the lock nor the guard is asked.
	// If they came first, a lock busy for walletSignInWait or a guard that says no would refuse while the proof
	// stands: roamInWalletGuarded would log "keeps no restore proof", and its plan carry would be skipped (check 3 in
	// roamInWalletGuarded decides the carry).
	if walletRestoreLanded(walletPath, gen) {
		return nil
	}
	// A late landing refuses a lock it did not get (busy or unavailable), before it stages anything. After the move a
	// CLAIM no longer serializes with the restore on sessionMu, and any wallet-lock holder -- the departed session's
	// payRent, drainClaim across an /issue round trip -- can outlast walletSignInWait; an unlocked write and proof there
	// lose the claimed batch or the stored tokens while the proof stands, and a publisher runs right after. Refused,
	// nothing is written, the generation keeps no restore proof and walletNotRestored refuses every publisher. A later
	// locked retry (sealClaimedWallet's first retryWalletRestore, the periodic seal, a sign-out) MAY land it, but its
	// read can fail, and on walletLockUnavailable no retry lands it (retryWalletRestoreWithin refuses the same state):
	// that session publishes no wallet, and the store keeps it for the next sign-in. Nil-guard callers keep today's
	// unlocked path in the no-file branch.
	if mayWrite != nil && state != walletLocked {
		return errWalletNotRestored
	}
	if !lateMayWrite(mayWrite) {
		return errLateWriteDenied
	}
	_, had, err := walletFileBytes(walletPath)
	if err != nil {
		return err
	}
	if had {
		// The session wrote this generation's file (a claim) before the late landing: merge, never overwrite.
		if state != walletLocked {
			return errWalletNotRestored
		}
		var stored Wallet
		if json.Unmarshal(pt, &stored) != nil {
			return errWalletUnparsable
		}
		land, err := stageWalletLanding(walletPath, gen, true)
		if err != nil {
			return err
		}
		local, err := loadWallet(walletPath)
		if err != nil {
			discardWalletLanding(land)
			return err
		}
		if err := saveWallet(walletPath, mergeLateRestore(&stored, local)); err != nil {
			discardWalletLanding(land)
			return err
		}
		walletFileLandedHook(walletPath)
		return proveWalletLanding(land)
	}
	land, err := stageWalletLanding(walletPath, gen, true)
	if err != nil {
		return err
	}
	var restored Wallet
	if json.Unmarshal(pt, &restored) == nil {
		// NWP-20261031-01: a restored token is held, so seen; a failure nothing can record refuses the landing.
		if err := noteWalletSeen(walletPath, &restored); err != nil {
			discardWalletLanding(land)
			return err
		}
	}
	if err := putWalletBytes(walletPath, pt); err != nil {
		discardWalletLanding(land)
		return err
	}
	walletFileLandedHook(walletPath)
	return proveWalletLanding(land)
}

// walletFileBytes reads walletPath as it stands: (bytes, true) when it exists, (nil, false) when it does not, and an
// error when it cannot be read -- a restore that could not be undone must not start.
func walletFileBytes(walletPath string) ([]byte, bool, error) {
	b, err := os.ReadFile(walletPath)
	if err == nil {
		return b, true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	return nil, false, err
}

// putWalletBytes makes walletPath hold b (temp+rename).
func putWalletBytes(walletPath string, b []byte) error {
	tmp := walletPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, walletPath)
}

// walletLanding is a restore -- the roam-in's (writeRestoredWallet) or a retry's merge (retryWalletRestoreWithin) --
// staged so that NOTHING AFTER THE FILE LANDS ALLOCATES (NWP-20261013-20, pass 5). Pass 4 wrote the proof only after
// the file had landed, and undid a refused proof by writing the old file back: both new files in the same tmpfs, so
// the disk that refused the first write could refuse the undo too, and a session was left holding the stored wallet
// with no proof (a fix review reproduced it, and the next retry published a spent nonce back into the stored wallet).
// Now the proof's temp file and a copy of the file the landing replaces (wallet.json.prev) are written FIRST, under
// the lock; a disk that refuses either refuses before the file is touched, and nothing is merged. After the file
// lands only renames remain -- the proof into place, or the copy back over the file -- and a rename inside one tmpfs
// directory needs no new page. Only a landing that changes the file (changesFile) is undone through the file: prev is
// its kept copy, renamed back, or "" when there was no file, which the undo then removes. A landing that changes no
// file -- a retry that proved there is no stored wallet -- is undone by discarding its staging alone, and the file,
// which holds the session's own claimed tokens, is left as it is (pass 6: pass 5 took that landing's "" prev for "there
// was no file" and removed the file, so the claimed credit was gone and the sign-out had none to warn about; a fix
// review reproduced it). Caller holds the wallet lock throughout.
type walletLanding struct {
	walletPath, proof, proofTmp string
	prev                        string
	changesFile                 bool
}

// walletPrevPath is the copy a staged landing keeps of the file it replaces. Named wallet.json.*, so the wipe leaves
// it; removeWallet removes it, as it does a save's stray temp file.
func walletPrevPath(walletPath string) string { return walletPath + ".prev" }

// walletRestoreFileLanded, when set (tests only), runs the moment a landing's file write has landed: right after
// writeRestoredWallet's putWalletBytes and right after the retry's merge is saved (a retry that proved there is no
// stored wallet writes no file and does not run it). From there to the proof's rename the landing may allocate
// nothing, so a test that makes the disk refuse every new file here convicts any write placed after the file lands.
var walletRestoreFileLanded func(walletPath string)

// walletFileLandedHook runs walletRestoreFileLanded when a test set it.
func walletFileLandedHook(walletPath string) {
	if walletRestoreFileLanded != nil {
		walletRestoreFileLanded(walletPath)
	}
}

// stageWalletLanding writes generation gen's proof to its temp file and, when the landing changes the file
// (changesFile) and there is one, a copy of it aside. Any failure removes what it staged and answers
// errWalletProofNotWritten (or the read error): nothing has been merged, and nothing is proven.
func stageWalletLanding(walletPath, gen string, changesFile bool) (*walletLanding, error) {
	if err := walletProofGenOK(gen); err != nil {
		return nil, err
	}
	l := &walletLanding{walletPath: walletPath, proof: walletRestoreLandedPath(walletPath, gen), changesFile: changesFile}
	l.proofTmp = l.proof + ".tmp"
	var prev []byte
	had := false
	if changesFile {
		var err error
		if prev, had, err = walletFileBytes(walletPath); err != nil {
			return nil, err
		}
	}
	if err := os.WriteFile(l.proofTmp, []byte(walletLandedProofHead+gen), 0o600); err != nil {
		discardWalletLanding(l)
		return nil, walletProofForfeited(err)
	}
	if had {
		l.prev = walletPrevPath(walletPath)
		if err := os.WriteFile(l.prev, prev, 0o600); err != nil {
			discardWalletLanding(l)
			return nil, walletProofForfeited(fmt.Errorf("the copy an undo would need could not be kept: %w", err))
		}
	}
	return l, nil
}

// proveWalletLanding renames the staged proof into place once the file has landed, and drops the kept copy. A rename
// that fails forfeits the proof and undoes the landing (undoWalletLanding).
func proveWalletLanding(l *walletLanding) error {
	if err := os.Rename(l.proofTmp, l.proof); err != nil {
		ferr := walletProofForfeited(err)
		undoWalletLanding(l)
		return ferr
	}
	if l.prev != "" {
		os.Remove(l.prev)
	}
	return nil
}

// undoWalletLanding puts back the file a landing replaced -- the kept copy renamed over it, or the file removed when
// there was none -- and removes what the staging left. A landing that changed no file (changesFile false) leaves the
// file alone: it is the session's own. An undo that fails too leaves the session holding the stored wallet with no
// proof: the window the header of this file names, logged as such.
func undoWalletLanding(l *walletLanding) {
	if !l.changesFile {
		discardWalletLanding(l)
		return
	}
	var err error
	if l.prev != "" {
		err = os.Rename(l.prev, l.walletPath)
	} else if rerr := os.Remove(l.walletPath); rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
		err = rerr
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet: WARNING the restore could not be undone either (%v) -- this session "+
			"holds the stored wallet without a proof: it still publishes none, but a later retry merges the stored "+
			"tokens in again, and one spent meanwhile would come back dead (NWP-20261013-20)\n", err)
	}
	discardWalletLanding(l)
}

// discardWalletLanding removes a staging's temp proof and kept copy (whichever exist).
func discardWalletLanding(l *walletLanding) {
	os.Remove(l.proofTmp)
	if l.prev != "" {
		os.Remove(l.prev)
	}
}

// roamInWallet is the roam-in's whole wallet block: resolve the profile's key, restore its wallet, retry a pending
// plan carry. The restore proof for the current generation is written only when the restore lands or a strict read
// proves there is no stored wallet; anything else -- a failed read, a panic in resolveDK, an unreadable generation --
// leaves the generation without one, with one FAILED line naming neither the profile nor a store key
// (logSafeStoreErr). Since NWP-20261116-03 (h46 #1) handleRoamIn runs it in the sign-in's late job, after the reply,
// as roamInWalletGuarded; the proof rule is unchanged.
//
// retryPlanCarry runs only after a landed restore (or a proven absence): it reads "no plan" off the wallet file, and
// with no file it would drop the outstanding carry record of a plan the stored wallet holds.
func roamInWallet(base, name, pass string, se []byte, walletPath string) {
	roamInWalletGuarded(base, name, pass, se, walletPath, nil)
}

// roamInWalletGuarded is roamInWallet for the late job: mayWrite (nil = always) is asked before anything is read,
// under the wallet lock just before the landing writes (writeRestoredWallet, pullWalletStrictGuarded), and again
// before the plan carry.
func roamInWalletGuarded(base, name, pass string, se []byte, walletPath string, mayWrite func() bool) {
	landed := false
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		if landed {
			// The restore and its proof are in place; what failed came after (retryPlanCarry). The session's wallet
			// is the stored one and publishes as usual -- it must not be reported as a failed read.
			fmt.Fprintf(os.Stderr, "[logind] roam-in: the wallet restore landed; a later step of the wallet block "+
				"failed (%s) (NWP-20261013-20)\n", logSafeStoreErr("wallet", panicAsErr(r)))
			return
		}
		walletRestoreFailedLog(panicAsErr(r))
	}()
	if !lateMayWrite(mayWrite) {
		fmt.Fprintf(os.Stderr, "[logind] roam-in: the late wallet restore was not started -- the sign-in's late work "+
			"was abandoned or its session ended; this generation keeps no restore proof and publishes no wallet (h46 #1)\n")
		return
	}
	dk := resolveDK(base, name, pass, se)
	if err := pullWalletStrictGuarded(base, name, pass, dk, walletPath, mayWrite); err != nil {
		switch {
		case errors.Is(err, errLateWriteDenied):
			fmt.Fprintf(os.Stderr, "[logind] roam-in: the late wallet restore was not written -- the sign-in's late "+
				"work was abandoned or its session ended; this generation keeps no restore proof and publishes no "+
				"wallet (h46 #1)\n")
		case errors.Is(err, errWalletNotRestored):
			fmt.Fprintf(os.Stderr, "[logind] roam-in: the late wallet restore read landed but the wallet lock was not "+
				"taken within walletSignInWait -- nothing written; this generation keeps no restore proof, and a later "+
				"locked retry (Add credits, the periodic seal, a sign-out) may land it (h46 #1)\n")
		case !errors.Is(err, errWalletProofNotWritten): // that one logged itself (markWalletRestoreLanded)
			walletRestoreFailedLog(err)
		}
		return
	}
	landed = true
	// Asked again before the carry: retryPlanCarry WRITES (rebindPlanReporting moves plan grants at the gateway;
	// dropBillPrev rewrites the vault head and the recovery ref inside a cap bracket), and in the late job it could
	// start after a LOGOUT, DELETE or cold lock went ahead at the bound. Skipped, the carry record stays and the next
	// sign-in retries it. The carry also takes the guard (retryPlanCarryGuarded): its head read can block past the
	// bound, so it asks again after that read and before each rebind, each marker write and the record edit, and
	// dropBillPrevGuarded carries it into its bracket. Only a rebindPlanReporting call already in flight is part of
	// the bounded window.
	if !lateMayWrite(mayWrite) {
		fmt.Fprintf(os.Stderr, "[logind] roam-in: the plan carry was not run -- the sign-in's late work was abandoned "+
			"or its session ended; the carry record stays and the next sign-in retries it (h46 #1)\n")
		return
	}
	if dk != nil {
		roamInPlanCarry(base, name, pass, dk, walletPath, mayWrite)
	}
}

// roamInPlanCarry is retryPlanCarryGuarded, a variable so a test can make the step after a landed restore fail.
var roamInPlanCarry = retryPlanCarryGuarded

// walletRestoreFailedLog is the roam-in's one FAILED line.
func walletRestoreFailedLog(err error) {
	fmt.Fprintf(os.Stderr, "[logind] roam-in: wallet read FAILED after retries (%s) -- this session will not "+
		"publish a wallet; the stored wallet is untouched (NWP-20261013-20)\n", logSafeStoreErr("wallet", err))
}

// mergeLateRestore is the wallet a late restore leaves on disk: the stored wallet plus every token this session holds
// that the stored one does not, and the session's monotonic facts merged forward (walletForPublish).
//
// ⚠ A TOKEN UNION, WHICH walletForPublish REFUSES, AND WHY IT IS SAFE HERE ONLY. That refusal is about two copies of
// ONE wallet: a union there resurrects nonces one side has already spent. Here the sides are disjoint by
// construction. The session never held the stored wallet -- its generation has no restore proof, the proof is
// renamed into place the moment a restore lands, and a restore whose proof the disk refuses is undone (bar the window
// the header of this file names) -- so it can have spent none of the stored tokens, and every token in its file was
// minted in this session (a claim), so none can be in the stored set. Tokens the session minted and then spent are
// already gone from its file. Deduplicated by nonce (and a blind token by its message) all the same.
func mergeLateRestore(stored, local *Wallet) *Wallet {
	out := Wallet{}
	if stored != nil {
		out = *stored
		out.Tokens = append([]Token(nil), stored.Tokens...)
		out.BlindTokens = append([]BlindToken(nil), stored.BlindTokens...)
	}
	// The pending claim codes (NWP-20261125-05): the union of both sides, stored first, deduplicated. Safe for the
	// reason the token union is: the session never held the stored wallet, so it cleared none of the stored codes.
	out.PendingClaims = nil
	haveCode := map[string]bool{}
	var codes []string
	if stored != nil {
		codes = append(codes, stored.PendingClaims...)
	}
	if local != nil {
		codes = append(codes, local.PendingClaims...)
	}
	for _, c := range codes {
		if !haveCode[c] {
			haveCode[c] = true
			out.PendingClaims = append(out.PendingClaims, c)
		}
	}
	// The miss hashes (NWP-20261202-01): both sides' union, stored first, kept only for a code the merged list holds.
	var stMiss, loMiss []string
	if stored != nil {
		stMiss = stored.PendingClaimMisses
	}
	if local != nil {
		loMiss = local.PendingClaimMisses
	}
	out.PendingClaimMisses = pendingClaimMissesFor(out.PendingClaims, stMiss, loMiss)
	if local == nil {
		return &out
	}
	// The waiting purchases, in order (NWP-20261031-07): the stored wallet's waiting purchase and queue, then the
	// session's. Decided BEFORE the tokens are unioned, because planPending reads each wallet's own balance. The first
	// is the plan that activates next; walletForPublish below keeps the plan fields verbatim while any wait.
	var waiting []PlanSpec
	haveID := map[string]bool{} // a purchase both copies hold is one purchase (h60 #14)
	add := func(s PlanSpec) {
		if s.ID != "" && haveID[s.ID] {
			return
		}
		haveID[s.ID] = true
		waiting = append(waiting, s)
	}
	for _, w := range []*Wallet{stored, local} {
		if w == nil {
			continue
		}
		if w.planPending() {
			add(PlanSpec{ID: w.PlanID, GB: w.PlanGB, Periods: w.PlanPeriods, Keep: w.PlanKeep, Convert: w.PlanConvert})
		}
		for _, s := range w.PlanQueue {
			add(s)
		}
	}
	out.PlanQueue = nil
	if len(waiting) > 0 {
		out.PlanGB, out.PlanPeriods, out.PlanKeep = waiting[0].GB, waiting[0].Periods, waiting[0].Keep
		out.PlanConvert = waiting[0].Convert
		out.PlanID = waiting[0].ID
		if len(waiting) > 1 {
			out.PlanQueue = waiting[1:]
		}
	}
	have := make(map[string]bool, len(out.Tokens)+len(out.BlindTokens))
	for _, t := range out.Tokens {
		have["t\x00"+t.Nonce] = true
	}
	for _, t := range out.BlindTokens {
		have["b\x00"+t.Msg] = true
	}
	for _, t := range local.Tokens {
		if !have["t\x00"+t.Nonce] {
			out.Tokens = append(out.Tokens, t)
		}
	}
	for _, t := range local.BlindTokens {
		if !have["b\x00"+t.Msg] {
			out.BlindTokens = append(out.BlindTokens, t)
		}
	}
	if local.FreeFullEpoch > out.FreeFullEpoch {
		out.FreeFullEpoch = local.FreeFullEpoch
	}
	if local.AccountPlanGB != 0 {
		out.AccountPlanGB = local.AccountPlanGB // the gateway's latest answer, and this session asked last
	}
	if len(local.AccountPlans) != 0 {
		out.AccountPlans = local.AccountPlans // the gateway's latest list, and this session asked last
	}
	return walletForPublish(local, &out, nil) // nil: this union is already the right one (above)
}

// retryWalletRestore reads the wallet once more for a session whose generation has no restore proof, so a store that
// is back makes the session's wallet publishable again, waiting at most walletSignInWait for the wallet lock (a
// person is waiting on every caller but the periodic seal and the sign-out, which pass their own bound). gen is the
// generation the CALLER captured before it read the session's credentials or anything from the store.
func retryWalletRestore(base, name, pass string, dk []byte, walletPath, gen string) error {
	return retryWalletRestoreWithin(base, name, pass, dk, walletPath, gen, walletSignInWait)
}

// retryWalletRestoreWithin is retryWalletRestore with the lock wait in the caller's hands. nil when generation gen
// has its proof -- it had one already, or this read landed: the stored wallet is merged into the file
// (mergeLateRestore) and the proof written, both UNDER THE WALLET LOCK. errWalletNotRestored when the read fails
// again; when the lock is busy or unavailable (a holder that loaded the file before the merge would save its copy --
// without the stored tokens -- over the merged one at the same generation, after the proof had made it publishable:
// the hole a fix review reproduced, stored 10 -> the session's 2); when the proof cannot be written (it is staged
// before the merge, so a refused write merges nothing, and a refused rename after it undoes the merge by a rename; a
// proven absence merged nothing, and its refused rename leaves the file as it was: stageWalletLanding); and whenever
// the wallet is not at gen, checked BEFORE the read and again UNDER THE LOCK. That last refusal is what keeps a retry
// that read session A's credentials -- the periodic seal reads them before its retry runs -- from merging A's stored
// wallet into the file of a session B that signed in meanwhile and proving B's generation (a fix review reproduced
// it). One read (getRef/getBlob retry inside it), so a caller a person waits on pays one store round trip at most.
func retryWalletRestoreWithin(base, name, pass string, dk []byte, walletPath, gen string, wait time.Duration) error {
	if !walletAtGeneration(walletPath, gen) {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the retried restore was asked for a generation the wallet is no longer "+
			"at (or one that cannot be read) -- refused; nothing merged, nothing proven (NWP-20261013-20)\n")
		return errWalletNotRestored
	}
	if walletRestoreLanded(walletPath, gen) {
		return nil
	}
	stored, _, err := readStoredWalletStrict(base, name, pass, dk)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the retried restore read FAILED too (%s) -- this session still "+
			"publishes no wallet (NWP-20261013-20)\n", logSafeStoreErr("wallet", err))
		return errWalletNotRestored
	}
	unlock, state := lockWalletWithin(walletPath, wait)
	defer unlock()
	if state != walletLocked {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the retried restore read landed but the wallet could not be locked -- "+
			"not merged; this session still publishes no wallet (NWP-20261013-20)\n")
		return errWalletNotRestored
	}
	if !walletAtGeneration(walletPath, gen) {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the wallet changed hands while the retried restore read -- not "+
			"merged, nothing proven (NWP-20261013-20)\n")
		return errWalletNotRestored
	}
	if walletRestoreLanded(walletPath, gen) {
		return nil // another retry landed while this one read: merging again would add the stored tokens twice over a spend
	}
	// Staged BEFORE the merge (pass 5): the proof's temp file and the copy an undo would rename back. A disk that
	// refuses either refuses here, with nothing merged. A proven absence (stored == nil) changes no file: it keeps no
	// copy, and its undo leaves the file alone (pass 6).
	_, serr := os.Stat(walletPath)
	had := serr == nil
	land, err := stageWalletLanding(walletPath, gen, stored != nil)
	if err != nil {
		return errWalletNotRestored
	}
	if stored != nil {
		local, lerr := loadWallet(walletPath)
		if lerr != nil {
			discardWalletLanding(land)
			return lerr
		}
		if err := saveWallet(walletPath, mergeLateRestore(stored, local)); err != nil {
			discardWalletLanding(land)
			return err
		}
		walletFileLandedHook(walletPath)
	}
	if err := proveWalletLanding(land); err != nil {
		return errWalletNotRestored
	}
	fmt.Fprintf(os.Stderr, "[agent] wallet: the retried restore read landed (stored wallet %v, local file %v) -- this "+
		"session publishes its wallet again (NWP-20261013-20)\n", stored != nil, had)
	return nil
}

// retrySessionWallet is the locked retry for the live session at dest (name, pass, se), run by the periodic seal and
// the sign-outs: nil when the session's wallet may publish, errWalletNotRestored when it may not -- a failed key
// resolution (a store read too) included. gen is the generation the caller captured BEFORE it read name and pass; a
// wallet no longer at it is refused before resolveDK reads anything (and again by retryWalletRestoreWithin).
func retrySessionWallet(dest, name, pass string, se []byte, gen string, wait time.Duration) (err error) {
	wp := walletPathFor(dest)
	if !walletAtGeneration(wp, gen) {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the session changed since its wallet generation was read -- no retry "+
			"(NWP-20261013-20)\n")
		return errWalletNotRestored
	}
	if walletRestoreLanded(wp, gen) {
		return nil
	}
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[agent] wallet: the retried restore could not resolve the key (%s) -- this session "+
				"still publishes no wallet (NWP-20261013-20)\n", logSafeStoreErr("wallet", panicAsErr(r)))
			err = errWalletNotRestored
		}
	}()
	return retryWalletRestoreWithin("s3", name, pass, resolveDK("s3", name, pass, se), wp, gen, wait)
}

// logoffWalletRetry is a sign-out's wallet step (decided 2026-10-15, "Retry, then warn"; LOGOUT): nothing
// when generation gen -- captured by the sign-out before it read the session -- has its restore proof; otherwise one
// locked retry of the read (walletLogoffRetryWait). It reports whether the gate must be told that credit claimed this
// session was lost: the retry did not land and the file holds credit. The sign-out goes ahead either way; with no
// proof, nothing publishes this generation's wallet.
func logoffWalletRetry(dest, name, pass string, se []byte, gen string) (creditLost bool) {
	if retrySessionWallet(dest, name, pass, se, gen, walletLogoffRetryWait) == nil {
		return false
	}
	lost := walletHoldsCredit(walletPathFor(dest))
	fmt.Fprintf(os.Stderr, "[logind] sign-out: this session never read its stored wallet and the retry did not land -- "+
		"signing out WITHOUT a wallet publish; the stored wallet is untouched (credit held this session: %v) "+
		"(NWP-20261013-20)\n", lost)
	return lost
}

// repairWalletBase is the store REPAIR-WALLET reads (a seam: the tests point it at their store).
var repairWalletBase = "s3"

// repairWalletAfterReadHook runs in a CONFIRM after the second strict read found damage and before the wallet lock is
// taken. Nil in production; a test moves the generation there.
var repairWalletAfterReadHook func()

// handleRepairWallet is "REPAIR-WALLET\n<CHECK|CONFIRM>\n" (Q153, decided 2026-10-20): the explicit, warned repair of
// a stored wallet the strict read finds DAMAGED, for the live online session at dest. Replies, one line:
//
//	CHECK    NONE | OK | DAMAGED | UNKNOWN
//	CONFIRM  NONE | OK REPAIRED | REFUSED OK | REFUSED UNKNOWN | REFUSED BUSY | REFUSED GEN
//	other    ERR
//
// NONE is a session that is not stored and online (no session, a throwaway, an offline session). Name and passphrase
// come only from the session, so the verb answers nothing about any other profile. It is offered for exactly the two
// damage cases (walletDamage) and never for a 403, a 5xx, a dropped read or a timeout: those answer UNKNOWN.
func handleRepairWallet(conn net.Conn, dest, op string) {
	wp := walletPathFor(dest)
	gen := walletGeneration(wp) // BEFORE the session is read, as every retry does
	name, pass, _ := readRoamSession(dest)
	var reply string
	switch {
	case name == "" || pass == "" || localOnlySession(dest):
		reply = "NONE"
	case op != "CHECK" && op != "CONFIRM":
		reply = "ERR"
	default:
		reply = repairWalletDamaged(wp, gen, name, pass, seFromSession(dest), op == "CONFIRM")
	}
	if op == "CONFIRM" && reply != "NONE" && reply != "ERR" {
		fmt.Fprintf(os.Stderr, "[agent] wallet: REPAIR-WALLET CONFIRM -> %s (NWP-20261103-03)\n", reply)
	}
	fmt.Fprintf(conn, "%s\n", reply)
}

// repairWalletDamaged answers a CHECK (confirm false) or a CONFIRM for generation gen of the wallet at wp. A CONFIRM
// reads the store again, and only on damage takes the wallet lock, rechecks the generation under it and writes the
// generation's restore proof: the file already holds only the session's own tokens (the sign-in's read failed, so
// nothing stored was merged), so the proof is all "start fresh" needs, and the next publish carries those tokens.
//
// If decisions-needed-2026-10-31 #1 is answered (b), the slice that builds that answer must treat a repaired
// generation's damaged stored copy as absent, so a repaired session's publish is not held back by the very copy the
// user agreed to give up.
func repairWalletDamaged(wp, gen, name, pass string, se []byte, confirm bool) string {
	v := repairWalletVerdict(wp, gen, name, pass, se)
	if !confirm {
		if v == "GEN" {
			return "UNKNOWN"
		}
		return v
	}
	if v != "DAMAGED" {
		return "REFUSED " + v
	}
	if repairWalletAfterReadHook != nil {
		repairWalletAfterReadHook()
	}
	unlock, state := lockWalletWithin(wp, walletSignInWait)
	defer unlock()
	if state != walletLocked {
		return "REFUSED BUSY" // a repair never runs unlocked
	}
	if !walletAtGeneration(wp, gen) {
		return "REFUSED GEN"
	}
	if walletRestoreLanded(wp, gen) {
		return "REFUSED OK" // a retry landed while this read ran
	}
	// The publishers merge a stored token this session never held (walletForPublish, by the seen-set). A damaged
	// copy that still opens (a hash mismatch) would feed its tokens into the repaired publish, so the generation's
	// seen-set is poisoned FIRST: walletSeen then reads nil in every process and the publish merges nothing from
	// the stored copy. No marker, no repair.
	if poisonSeen(wp, gen) != nil {
		return "REFUSED UNKNOWN"
	}
	// The publishers merge a stored token this session never held (walletForPublish, by the seen-set). A damaged
	// copy that still opens (a hash mismatch) would feed its tokens into the repaired publish, so the generation's
	// seen-set is poisoned FIRST: walletSeen then reads nil in every process and the publish merges nothing from
	// the stored copy. No marker, no repair.
	if poisonSeen(wp, gen) != nil {
		return "REFUSED UNKNOWN"
	}
	if markWalletRestoreLanded(wp, gen) != nil {
		return "REFUSED UNKNOWN" // it logged itself; no proof is anywhere
	}
	return "OK REPAIRED"
}

// repairWalletVerdict is one strict read of the session's stored wallet: OK (a standing proof, with no store read; a
// readable wallet; or provably none -- the ordinary retry is the path for those), DAMAGED, UNKNOWN (any other failure,
// a recovered panic included) or GEN (the generation moved, checked before anything is read from the store).
func repairWalletVerdict(wp, gen, name, pass string, se []byte) (v string) {
	if !walletAtGeneration(wp, gen) {
		return "GEN"
	}
	if walletRestoreLanded(wp, gen) {
		return "OK"
	}
	defer func() {
		if r := recover(); r != nil {
			v = "UNKNOWN"
		}
	}()
	dk := resolveDK(repairWalletBase, name, pass, se)
	_, _, err := readStoredWalletStrict(repairWalletBase, name, pass, dk)
	if err == nil {
		return "OK"
	}
	if walletDamage(err) {
		return "DAMAGED"
	}
	return "UNKNOWN"
}

// errStoredWalletExists is proveNoStoredWallet's answer for a profile that already has a stored wallet.
var errStoredWalletExists = errors.New("the profile already has a stored wallet")

// proveNoStoredWallet writes generation gen's restore proof for a wallet that will be published to a profile being
// MADE -- a create's staged claim (createAndReply), a throwaway's promote (promoteToStore), a provisioning push --
// once a strict read of the store proves the profile has no stored wallet for it to replace. errStoredWalletExists
// when it has one; an error, and no proof, for everything else: the read failed (a 403 included), the generation
// cannot be read (walletGenUnreadable), the proof could not be written. nil only with the proof on disk; any error
// and the caller refuses: publishing then could replace a wallet nobody read.
func proveNoStoredWallet(base, name, pass, walletPath, gen string) (err error) {
	if gen == walletGenUnreadable {
		return errors.New("the wallet generation cannot be read, so no restore proof can be written for it")
	}
	defer func() {
		if r := recover(); r != nil {
			err = panicAsErr(r)
		}
	}()
	if _, head, _ := headRefWith(base, name+"#wallet", pass, refProbeStrict); head != "" {
		return errStoredWalletExists
	}
	return markWalletRestoreLanded(walletPath, gen)
}

// pullWalletStrict is the strict restore of (name, pass)'s stored wallet into walletPath, for the roam-in
// (roamInWallet), the CLI's wallet-pull and the tests that read a stored wallet back: the plaintext written as the
// current generation's file when there is a stored wallet, and that generation's restore proof written when the
// restore landed or there provably is none. Any error leaves the generation without a proof and the file as it was:
// an unreadable generation, a failed or damaged read, a generation that moved while it read, a proof the disk
// refused (errWalletProofNotWritten; the restore is undone).
func pullWalletStrict(base, name, pass string, dk []byte, walletPath string) error {
	return pullWalletStrictGuarded(base, name, pass, dk, walletPath, nil)
}

// pullWalletStrictGuarded is pullWalletStrict with the late job's guard (h46 #1, nil = always), asked just before
// the landing writes: under the wallet lock in writeRestoredWallet, and before a proven absence's proof here.
func pullWalletStrictGuarded(base, name, pass string, dk []byte, walletPath string, mayWrite func() bool) error {
	gen, gerr := walletGenerationErr(walletPath)
	if gerr != nil {
		return fmt.Errorf("the wallet generation cannot be read: %w", gerr)
	}
	_, pt, err := readStoredWalletStrict(base, name, pass, dk)
	if err != nil {
		return err
	}
	if pt != nil {
		return writeRestoredWallet(walletPath, gen, pt, mayWrite)
	}
	// A standing proof needs no write, so neither a guard that says no may turn it into a refusal.
	if walletRestoreLanded(walletPath, gen) {
		return nil
	}
	if !lateMayWrite(mayWrite) {
		return errLateWriteDenied
	}
	return markWalletRestoreLanded(walletPath, gen)
}

// walletLogoffRetryWait bounds the sign-out's wait for the wallet lock before its one retried read. Longer than a
// sign-in's: nobody is in a chooser budget, the user is watching "Saving…", and a payRent lease that holds the lock
// is the likeliest holder; well inside logoffStallLimit.
var walletLogoffRetryWait = 60 * time.Second

// walletHoldsCredit reports that the wallet file at wp holds credit a lost publish loses: unspent tokens
// (NWP-20261128-31). A plan bought and not yet activated still holds its tokens, so the balance covers it. A plan
// whose tokens were spent is a grant the gateway holds under the profile's key, and the next lease relearns its term,
// so its PlanGB/PaidThrough record is not credit. A file that cannot be read counts as holding credit (the notice
// errs toward saying so).
func walletHoldsCredit(wp string) bool {
	if _, err := os.Stat(wp); os.IsNotExist(err) {
		return false
	}
	w, err := loadWallet(wp)
	if err != nil {
		return true
	}
	return w.balance() > 0
}

// ---- the gate's "credit could not be saved" notice (NWP-20261013-20, decided 2026-10-15; NWP-20261016-47) ----
//
// A session that ends without its wallet published -- a sign-out (LOGOUT) whose retried read failed,
// END-UNSAVED over a session that never read its stored wallet, or the gate's wipe of a cold-locked one -- loses the
// credit claimed during it. The reply that could say so is read by the session's own screen, and the reap switches to
// the gate within a fraction of a second, so the daemon RECORDS the notice instead and the GATE (user 0's chooser)
// shows it once and clears it. Content-free: the file holds the time it was recorded and nothing else -- no profile
// name, no amount -- and it lives in the state tmpfs, gone at power-off. Named wallet.json.* so
// wipeSessionState leaves it for the gate. Only a user-0 caller may read or clear it (creditLostCallerOK).
//
// Decided 2026-10-16, "warn and tell" (docs/product-decisions.md), for the two endings that recorded none:
//   - TELL: RESTART-UNSAVED's reboot clears the state tmpfs, so a restart that loses credit leaves the same notice on
//     durable storage instead (restartCreditLostPath, a time and nothing else), written after its last refusal and
//     shown by the gate after the boot through the same GET-CREDIT-LOST / CLEAR-CREDIT-LOST. A restart whose reboot
//     does not happen takes it back (retractRestartCreditLost, from removeRestartMarker): the session is given back
//     and nothing was lost.
//   - WARN: a sign-in that supersedes a parked cold-locked session (#123) records none, because the gate would show it
//     at its next appearance, where it reads as the new session's loss. The gate asks GET-PARKED-CREDIT BEFORE the
//     sign-in instead (parkedCreditReply) and lets the person cancel; the supersede still logs its one line
//     (noteSupersededColdLockCredit). The answer never reads the throwaway mark, so it cannot tell a stored profile
//     from a throwaway (parkedCreditUnsaved).

var creditLostMu sync.Mutex

func creditLostPath(dest string) string { return walletPathFor(dest) + ".creditlost" }

// restartCreditLostPath is RESTART-UNSAVED's notice for after the boot (NWP-20261016-47). /data/nowhere is durable f2fs
// (last-reboot lives beside it), so it survives the reboot that clears the state tmpfs; nothing in the boot path
// touches it (TestWarnAndTell_NothingElseRemovesTheRestartNotice). One line, the unix time, 0600; the gate's OK
// removes it (clearCreditLost). docs/threat-model.md lists it under "What user 0 keeps across a reboot". A var so tests
// point it at a temp file.
var restartCreditLostPath = "/data/nowhere/restart-credit-lost"

// creditLostCallerOK admits GET-CREDIT-LOST / CLEAR-CREDIT-LOST / GET-PARKED-CREDIT from user 0 only, handleGetRelogin's
// rule: a roamed session's apps must not learn that the previous session lost credit, nor clear the notice before the
// gate shows it, nor learn anything of a parked session.
func creditLostCallerOK(conn net.Conn) bool {
	u := ownerPeerUID(conn)
	return u >= 0 && u < 100000
}

// parkedCreditUnsaved reports that the wallet file at wp holds credit no wallet publish has carried: its generation
// never earned its restore proof, and it holds credit. Ending that session with no publish loses the credit. That is a
// stored session whose sign-in never read its stored wallet, and also a throwaway (or an offline session): it has no
// stored wallet to read, so its generation has no proof until "Save to your store" writes one (promoteToStore), and
// the credit claimed in it is carried by that promote or by nothing.
func parkedCreditUnsaved(wp string) bool {
	return walletNotRestored(wp, walletGeneration(wp)) && walletHoldsCredit(wp)
}

// parkedCreditLost is parkedCreditUnsaved for a STORED session only: local is the session's throwaway mark, and a
// throwaway's ending records no notice and logs no lost-credit line (its sign-out records none either). The one test
// behind both records of a parked session that ends with no publish -- the gate's wipe (noteCreditLostAtWipe) and a
// sign-in that supersedes it (noteSupersededColdLockCredit) -- so the two cannot drift apart. The gate's question
// before a supersede is NOT this one: it must not read the throwaway mark (parkedCreditReply).
func parkedCreditLost(wp string, local bool) bool {
	return !local && parkedCreditUnsaved(wp)
}

// noteCreditLostAtWipe is the gate's wipe of a cold-locked session (CLAIM-COLDLOCK: the 12-hour hard wipe and the
// failed-eviction wipe): that wipe publishes nothing, so a STORED session whose generation never earned its restore
// proof and whose file holds credit loses that credit, and the gate is told as after a sign-out. Caller has claimed
// the marker, under sessionMu. The caller then removes the session's wallet file (removeWallet, NWP-20261030-03), so
// this runs first: it reads the file, its generation and the restore proof.
func noteCreditLostAtWipe(dest, uid string, local bool) {
	if !parkedCreditLost(walletPathFor(dest), local) {
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] claim-coldlock user %s: the wiped session never read its stored wallet and holds "+
		"credit -- that credit is lost; the stored wallet is untouched and the session's wallet file is removed "+
		"(NWP-20261013-20, NWP-20261030-03)\n", uid)
	noteCreditLost(dest)
}

// supersedeLosesCredit is the #123 supersede's question, asked twice with one answer: a fresh sign-in on newUID ends
// the parked cold-locked session the marker names, and nothing publishes that session's wallet first, so the credit
// parkedCreditUnsaved finds in it is lost -- a stored session's and a throwaway's alike. parked is the parked uid (""
// with no marker). Only a parked session that is really superseded -- a marker naming another uid than the arriving
// one -- is judged: an ordinary sign-in has none. Who is told differs: the gate's warning is told for both kinds
// (parkedCreditReply), the log line for a stored session only (noteSupersededColdLockCredit).
func supersedeLosesCredit(dest, newUID string) (parked string, lost bool) {
	parked = coldLockedUID(dest)
	return parked, parked != "" && parked != newUID && parkedCreditUnsaved(walletPathFor(dest))
}

// parkedCreditReply is GET-PARKED-CREDIT's answer (NWP-20261016-47, decided 2026-10-16, "warn and tell"): "LOST" when a
// sign-in now would end a parked session whose credit is lost with it, else "NONE". The gate asks it at the sign-in
// tap, before it creates the new user, and warns on LOST. The arriving uid does not exist yet, and any uid it gets
// differs from the parked one (createRoamUser mints a fresh id), so none is passed. Content-free: a yes or no about the
// parked session's wallet, the same for every name and passphrase typed, and nothing is written.
//
// ⚠ BLIND LOGIN: it never reads the throwaway mark. "Welcome back, <name>" looks the same for a stored session and
// for the throwaway a wrong passphrase lands in, and anyone at the gate can ask this question (tap "Not you?", type
// anything, Cancel). An answer that held LOST back for a throwaway would tell them which one is parked: an existence
// oracle (docs/identity-model.md). A funded throwaway is a normal state (credit claimed before "Save to your store"),
// and its credit is lost by the supersede just the same, so LOST is true of it and the warning says nothing about
// which kind the session is (docs/product-decisions.md, 2026-10-16).
func parkedCreditReply(dest string) string {
	if _, lost := supersedeLosesCredit(dest, ""); lost {
		return "LOST"
	}
	return "NONE"
}

// noteSupersededColdLockCredit is the #123 supersede's half (handleRoamIn, handleRoamInOffline): a fresh sign-in that
// replaces a parked cold-locked session drops its marker and removes its wallet, and nothing publishes that wallet
// first. When supersedeLosesCredit says the credit is lost and the parked session is a stored one (parkedLocal false,
// the gate's wipe's rule, parkedCreditLost), this logs ONE content-free line naming the parked uid only. It records NO
// gate notice: the gate shows the notice at its next appearance (the NEW session's first cold lock, or its end;
// onResume asks GET-CREDIT-LOST every time), where its text ("credit added during the last session") would read as
// that session's loss. The person was warned before this sign-in instead (GET-PARKED-CREDIT, decided 2026-10-16, "warn
// and tell"), from the same question. Nothing here reaches the reply, which stays independent of what the parked
// session held. Called before the marker is removed and before removeWallet moves the generation on; parkedLocal is
// the parked session's throwaway mark, read before the new session marks its own.
func noteSupersededColdLockCredit(dest, newUID string, parkedLocal bool) {
	parked, lost := supersedeLosesCredit(dest, newUID)
	if !lost || parkedLocal {
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] roam-in: the superseded cold-locked session (user %s) never read its stored wallet "+
		"and holds credit -- that credit is lost; the stored wallet is untouched (NWP-20261013-20)\n", parked)
}

// noteCreditLost records the notice (the newest wins).
func noteCreditLost(dest string) {
	creditLostMu.Lock()
	defer creditLostMu.Unlock()
	p := creditLostPath(dest)
	tmp := p + ".tmp"
	err := os.WriteFile(tmp, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o600)
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		os.Remove(tmp)
		fmt.Fprintf(os.Stderr, "[logind] the gate's lost-credit notice could not be recorded (%v) (NWP-20261013-20)\n", err)
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] recorded the gate's lost-credit notice (NWP-20261013-20)\n")
}

// noteRestartCreditLost leaves RESTART-UNSAVED's notice at restartCreditLostPath: stamp, and nothing else (the newest
// wins). Called once the restart can no longer refuse, just before its reply; stamp is the one its restart marker
// carries, so a reboot that does not happen takes back exactly this notice. Best-effort, like recordRebootReason: a
// failed write is logged and the restart goes ahead -- the restarting screen has already said the credit is lost.
// temp+rename under creditLostMu, so a reader never sees a torn notice; a .tmp a crash leaves is dropped at the next
// daemon start (dropRestartCreditLostTmp).
func noteRestartCreditLost(stamp string) {
	creditLostMu.Lock()
	defer creditLostMu.Unlock()
	tmp := restartCreditLostPath + ".tmp"
	err := os.WriteFile(tmp, []byte(stamp), 0o600)
	if err == nil {
		err = os.Rename(tmp, restartCreditLostPath)
	}
	if err != nil {
		os.Remove(tmp)
		fmt.Fprintf(os.Stderr, "[logind] the restart's lost-credit notice could not be recorded (%v) -- the gate will "+
			"not be told after the boot (NWP-20261016-47)\n", err)
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] recorded the restart's lost-credit notice for the gate after the boot (NWP-20261016-47)\n")
}

// retractRestartCreditLost takes back the restart notice recorded with stamp: its restart marker is being removed with
// the phone still up, so the reboot did not happen (the session is given back, or the restart was refused before it
// wrote the notice) and nothing was lost by it. Only a notice holding exactly stamp goes -- an older one, from an
// earlier boot, still waits for the gate. A no-op for "".
func retractRestartCreditLost(stamp string) {
	if stamp == "" {
		return
	}
	creditLostMu.Lock()
	defer creditLostMu.Unlock()
	if b, err := os.ReadFile(restartCreditLostPath); err == nil && strings.TrimSpace(string(b)) == stamp {
		os.Remove(restartCreditLostPath)
		fmt.Fprintf(os.Stderr, "[logind] the restart did not happen: its lost-credit notice is taken back (NWP-20261016-47)\n")
	}
}

// dropRestartCreditLostTmp removes a restartCreditLostPath .tmp left by a crash between noteRestartCreditLost's write and
// its rename. Run once at daemon start, when no write can be in flight (the writer lives in this process).
func dropRestartCreditLostTmp() { os.Remove(restartCreditLostPath + ".tmp") }

// creditLostStamp reads a notice file: its time and true, or false for a missing file or one that is not a positive
// time.
func creditLostStamp(p string) (string, bool) {
	b, err := os.ReadFile(p)
	if err != nil {
		return "", false
	}
	ts, perr := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if perr != nil || ts <= 0 {
		return "", false
	}
	return strconv.FormatInt(ts, 10), true
}

// restartNoticeDue reports that the restart notice holding stamp may be shown: its reboot has happened. While the restart
// that wrote it is still pending in this boot, its marker (same stamp) is still in the state tmpfs, and the notice is
// neither shown nor counted.
func restartNoticeDue(dest, stamp string) bool {
	return restartMarkerTell(dest) != stamp
}

// creditLostReply is GET-CREDIT-LOST's answer: "NOTICE <unix seconds>" while a notice is due, else "NONE". The restart's
// notice is answered first: it predates every notice recorded since the boot. The gate clears each by its time, so a
// second one is shown at the gate's next appearance.
func creditLostReply(dest string) string {
	creditLostMu.Lock()
	defer creditLostMu.Unlock()
	if ts, ok := creditLostStamp(restartCreditLostPath); ok && restartNoticeDue(dest, ts) {
		return "NOTICE " + ts
	}
	if ts, ok := creditLostStamp(creditLostPath(dest)); ok {
		return "NOTICE " + ts
	}
	return "NONE"
}

// clearCreditLost is CLEAR-CREDIT-LOST <stamp>: the gate showed the notice recorded at stamp, so it goes -- and only
// that one, so a newer notice recorded while the gate showed the old one, or the other of the two, is still shown:
// "STALE" says one is left. A restart notice whose reboot has not happened is neither cleared nor counted.
func clearCreditLost(dest, stamp string) string {
	creditLostMu.Lock()
	defer creditLostMu.Unlock()
	s := strings.TrimSpace(stamp)
	stale := false
	for _, p := range []string{restartCreditLostPath, creditLostPath(dest)} {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		got := strings.TrimSpace(string(b))
		switch {
		case p == restartCreditLostPath && !restartNoticeDue(dest, got):
			// its reboot has not happened: not shown yet, so neither cleared nor counted
		case got == s:
			os.Remove(p)
		default:
			stale = true
		}
	}
	if stale {
		return "STALE"
	}
	return "OK"
}

// rotateWalletOurs is the walletOurs a signed-in passphrase rotation passes to rotateVault: the live session's file
// is this profile's wallet only when its restore proof stands. When it does not, the fold is refused (the rule
// above), so treating the file as ours would skip carryWallet and leave the stored wallet at the old passphrase's
// head, where nothing reads it again. Not ours, the stored head is RELOCATED (carryWallet: a pointer move, never a
// merge) and this session's own new credit stays unpublished, as before the rotation.
func rotateWalletOurs(live bool, walletPath string) bool {
	return live && walletRestoreLanded(walletPath, walletGeneration(walletPath))
}
