package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
)

// The wallet's SEEN-SET (NWP-20261031-01, decided 2026-10-20): every token this session's wallet file has ever held,
// as one key per token (and one per pending claim code). walletForPublish uses it to tell a token the OTHER phone
// added (never held here: kept) from one this session held and has since spent (held here: not resurrected).
//
// walletPath+".seen", 0600. First line the generation the set belongs to (THE GENERATION, wallet_lock.go), then one key
// per line: "t:"+nonce for a plain token, "b:"+hex(sha256(msg)) for a blind one. NEVER the signature, and a blind
// token's message is hashed, so the file holds no spendable token. A pending claim code (Wallet.PendingClaims,
// NWP-20261125-05) is one more key, "c:"+hex(sha256(code)), never the code itself, so the file holds nothing spendable.
// It lives beside the wallet in the session's tmpfs and nowhere else: it is not sealed, never roams, and goes with the
// wallet (removeWallet, dropWalletIfUnchanged) and with the power-off wipe, so a new session starts with none and
// publishes by the unread-set rule.
//
// Callers hold the wallet lock, as for every write of the file.

// seenPoisoned holds "walletPath\x00generation" for every set whose update FAILED. Such a set is short -- it lacks a
// token this session held -- and a short set would let walletForPublish resurrect that token as the other phone's
// credit. So a failure deletes the file and writes a marker beside it (walletPath+".seen.bad", the generation, 0600,
// session tmpfs): while the marker names the current generation nothing is noted and walletSeen reads nil, in EVERY
// agent process sharing the wallet (the periodic and logoff seals are separate processes, wallet_lock.go), so none can
// recreate an incomplete set. The publish merges nothing from the stored copy (the old behaviour) for the rest of
// that generation. A marker that cannot be written fails the save itself (noteWalletSeen returns the error), so no wallet holding an
// unrecorded token lands. Neither names a token.
var (
	seenPoisonMu sync.Mutex
	seenPoisoned = map[string]bool{}
)

func seenPoisonKey(walletPath, gen string) string { return walletPath + "\x00" + gen }

func seenBadPath(walletPath string) string { return walletPath + ".seen.bad" }

func isSeenPoisoned(walletPath, gen string) bool {
	seenPoisonMu.Lock()
	mem := seenPoisoned[seenPoisonKey(walletPath, gen)]
	seenPoisonMu.Unlock()
	if mem {
		return true
	}
	raw, err := os.ReadFile(seenBadPath(walletPath))
	return err == nil && strings.TrimSpace(string(raw)) == gen
}

// poisonSeen marks the set of this generation unusable for every process and removes any file left behind. It
// returns an error, touching nothing, when the marker cannot be written: a process-local flag would leave the periodic
// and logoff agents free to rebuild an incomplete set, so the caller must refuse the save instead.
func poisonSeen(walletPath, gen string) error {
	seenFile := walletPath + ".seen"
	tmpFile := seenFile + ".tmp"
	if err := os.WriteFile(seenBadPath(walletPath), []byte(gen+"\n"), 0o600); err != nil {
		return err
	}
	seenPoisonMu.Lock()
	seenPoisoned[seenPoisonKey(walletPath, gen)] = true
	seenPoisonMu.Unlock()
	os.Remove(seenFile)
	os.Remove(tmpFile)
	return nil
}

// walletTokenKeys lists the seen-set keys of w's tokens.
func walletTokenKeys(w *Wallet) []string {
	if w == nil {
		return nil
	}
	keys := make([]string, 0, len(w.Tokens)+len(w.BlindTokens))
	for _, t := range w.Tokens {
		keys = append(keys, "t:"+t.Nonce)
	}
	for _, t := range w.BlindTokens {
		keys = append(keys, blindSeenKey(t))
	}
	return keys
}

// walletSeenKeys lists every seen-set key of w: its tokens' (walletTokenKeys) and one per pending claim code. A separate
// helper so walletTokenKeys stays tokens only.
func walletSeenKeys(w *Wallet) []string {
	keys := walletTokenKeys(w)
	if w == nil {
		return keys
	}
	for _, c := range w.PendingClaims {
		keys = append(keys, pendingClaimSeenKey(c))
	}
	return keys
}

// pendingClaimSeenKey keys a pending claim code by its hash. Never the code: the code is a paid bearer instrument.
func pendingClaimSeenKey(code string) string {
	sum := sha256.Sum256([]byte(code))
	return "c:" + hex.EncodeToString(sum[:])
}

// blindSeenKey keys a blind token by the hash of its signed message. Not by its signature: the signature is what
// spends it, and a randomised or re-encoded signature must not make the same token look new.
func blindSeenKey(t BlindToken) string {
	sum := sha256.Sum256([]byte(t.Msg))
	return "b:" + hex.EncodeToString(sum[:])
}

// plainSeenKey keys a plain token by its nonce.
func plainSeenKey(t Token) string { return "t:" + t.Nonce }

// noteWalletSeen adds w's seen-set keys (walletSeenKeys) to the seen-set for the wallet's current generation; a set of
// another generation, or none, is started afresh, and a set that is there but cannot be read whole poisons the
// generation like a failed write. A failure is logged and swallowed (the save it rides on must still land) and POISONS
// the generation's set (poisonSeen): a short set would resurrect a spent token, so none is better than a short one. The
// one error returned is a failure that could not even be recorded: the caller must NOT land the wallet then.
func noteWalletSeen(walletPath string, w *Wallet) error {
	gen, err := walletGenerationErr(walletPath)
	if err != nil {
		return nil // an unreadable generation is no generation: walletSeen would not match it either
	}
	if isSeenPoisoned(walletPath, gen) {
		return nil
	}
	seen, st, rerr := readWalletSeen(walletPath, gen)
	if st == seenUnreadable {
		// A set that is there but cannot be read whole is NOT a fresh start: rewriting it from w alone would publish a
		// SHORT set, and a token this session held and spent would come back from the stored copy. Poison it, as a
		// failed write does.
		fmt.Fprintf(os.Stderr, "[agent] wallet: the seen-set could not be read whole (%v) -- this generation merges nothing from the stored copy (NWP-20261031-01)\n", rerr)
		return poisonSeenOrFail(walletPath, gen, rerr)
	}
	if seen == nil {
		seen = map[string]bool{} // absent, or of another generation: start afresh
	}
	var added bool
	for _, k := range walletSeenKeys(w) {
		if !seen[k] {
			seen[k] = true
			added = true
		}
	}
	if !added {
		if _, serr := os.Stat(walletPath + ".seen"); serr == nil {
			return nil
		}
	}
	var b bytes.Buffer
	b.WriteString(gen + "\n")
	for k := range seen {
		b.WriteString(k + "\n")
	}
	tmp := walletPath + ".seen.tmp"
	if err := os.WriteFile(tmp, b.Bytes(), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the seen-set could not be written (%v) -- a publish merges nothing from the stored copy for this generation (NWP-20261031-01)\n", err)
		return poisonSeenOrFail(walletPath, gen, err)
	}
	if err := os.Rename(tmp, walletPath+".seen"); err != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the seen-set could not be renamed into place (%v) -- a publish merges nothing from the stored copy for this generation (NWP-20261031-01)\n", err)
		return poisonSeenOrFail(walletPath, gen, err)
	}
	return nil
}

// poisonSeenOrFail poisons the set after cause; when the marker cannot be written either, it returns an error.
func poisonSeenOrFail(walletPath, gen string, cause error) error {
	if perr := poisonSeen(walletPath, gen); perr != nil {
		return fmt.Errorf("seen-set update failed (%v) and so did its poison marker (%v)", cause, perr)
	}
	return nil
}

// walletSeen reads the seen-set for generation gen (readWalletSeen): nil when the file is absent, unreadable, or
// belongs to another generation (walletPublish then merges nothing from the stored copy: the old behaviour).
func walletSeen(walletPath, gen string) map[string]bool {
	seen, st, _ := readWalletSeen(walletPath, gen)
	if st != seenOK {
		return nil
	}
	return seen
}

// seenState is why readWalletSeen has, or has no, set.
type seenState int

const (
	seenOK         seenState = iota // the set of this generation, read whole
	seenAbsent                      // no .seen file
	seenOtherGen                    // the first line read cleanly and names another generation
	seenNoGen                       // the generation is unreadable or poisoned: no set is used or written
	seenUnreadable                  // the file is there and cannot be read whole
)

var errSeenEmpty = errors.New("the seen-set file is empty")

// readWalletSeen reads the seen-set for generation gen and says why it has none. The error is set for seenUnreadable
// only, and carries no path (seenCause), so it can be logged.
func readWalletSeen(walletPath, gen string) (map[string]bool, seenState, error) {
	if gen == walletGenUnreadable || isSeenPoisoned(walletPath, gen) {
		return nil, seenNoGen, nil
	}
	f, err := os.Open(walletPath + ".seen")
	if err != nil {
		if os.IsNotExist(err) {
			return nil, seenAbsent, nil
		}
		return nil, seenUnreadable, seenCause(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return nil, seenUnreadable, seenCause(err)
		}
		return nil, seenUnreadable, errSeenEmpty // the writer always writes the generation line first
	}
	if sc.Text() != gen {
		return nil, seenOtherGen, nil
	}
	seen := map[string]bool{}
	for sc.Scan() {
		if k := strings.TrimSpace(sc.Text()); k != "" {
			seen[k] = true
		}
	}
	if err := sc.Err(); err != nil {
		return nil, seenUnreadable, seenCause(err) // a line past the 16 MiB cap, or an I/O error
	}
	return seen, seenOK, nil
}

// seenCause strips the file path from err, so a log line carries the error text only.
func seenCause(err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err
	}
	return err
}
