package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"strings"
)

// The wallet's RESTORED RECORD (NWP-20261202-40, decided 2026-11-05, harvest 59 #10): every token this session's own
// sign-in restored from the stored copy, as one key per token. The gate's lost-credit notice (.creditlost) fires only
// for a token NOT in it: a restored token still in the file is still in the stored copy (a spent one has left the
// file), so a lost publish does not lose it. Only a token the session added (a claim, a purchase) is lost with the
// publish. No store read: the record is written where the restore lands.
//
// walletPath+".restored", 0600. Same format as the seen-set (wallet_seen.go): first line the generation the record
// belongs to (THE GENERATION, wallet_lock.go), then one key per line from walletTokenKeys -- tokens only, never a
// signature and never a claim code, so the file holds nothing spendable. It lives beside the wallet in the session's
// tmpfs and nowhere else: it is not sealed, never roams, and goes with the wallet (removeWallet,
// dropWalletIfUnchanged) and with the power-off wipe.
//
// It is written at the three restore landings (writeRestoredWallet's fresh and merge branches,
// retryWalletRestoreWithin's merge), and callers hold the wallet lock there. A record that is absent, unreadable or of
// another generation counts as empty, so the notice then gives today's answer (walletHoldsCredit). A short record only
// makes the notice fire more: the safe side.
//
// Every function here takes the wallet path as wp: the record is not the wallet file, and its writes run under the
// caller's lock (TestEveryWalletWriterTakesTheWalletLock counts writes on a walletPath-named argument).

// walletRestoredPath is the restored record of the wallet at wp.
func walletRestoredPath(wp string) string { return wp + ".restored" }

// readWalletRestored reads the restored record of generation gen: nil when the generation is unreadable, or the file
// is absent, cannot be read whole, or belongs to another generation.
func readWalletRestored(wp, gen string) map[string]bool {
	if gen == walletGenUnreadable {
		return nil
	}
	f, err := os.Open(walletRestoredPath(wp))
	if err != nil {
		return nil
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	if !sc.Scan() {
		return nil // empty, or an I/O error (a directory at the path): the writer always writes the generation line
	}
	if sc.Text() != gen {
		return nil
	}
	keys := map[string]bool{}
	for sc.Scan() {
		if k := strings.TrimSpace(sc.Text()); k != "" {
			keys[k] = true
		}
	}
	if sc.Err() != nil {
		return nil
	}
	return keys
}

// noteWalletRestored adds w's token keys (walletTokenKeys) to the restored record of the wallet's current generation;
// a record of another generation, or none, or one that cannot be read, is started afresh. An unreadable generation
// records nothing. It never refuses a landing: a failure logs one fixed line and removes the record, so the notice
// counts every token this session (today's answer).
func noteWalletRestored(wp string, w *Wallet) {
	gen, err := walletGenerationErr(wp)
	if err != nil {
		return // an unreadable generation is no generation: readWalletRestored would not match it either
	}
	keys := readWalletRestored(wp, gen)
	if keys == nil {
		keys = map[string]bool{}
	}
	for _, k := range walletTokenKeys(w) {
		keys[k] = true
	}
	var b bytes.Buffer
	b.WriteString(gen + "\n")
	for k := range keys {
		b.WriteString(k + "\n")
	}
	rec := walletRestoredPath(wp)
	tmp := rec + ".tmp"
	if err := os.WriteFile(tmp, b.Bytes(), 0o600); err == nil {
		if err := os.Rename(tmp, rec); err == nil {
			return
		}
	}
	fmt.Fprintf(os.Stderr, "[agent] wallet: the restored-token record could not be written -- the lost-credit notice "+
		"counts every token this session (NWP-20261202-40)\n")
	os.Remove(rec)
	os.Remove(tmp)
}

// walletHoldsUnrestoredCredit reports that the wallet file at wp holds a token the session's own sign-in did not
// restore: the credit a lost publish loses (decided 2026-11-05, harvest 59 #10). No record of the current generation
// gives walletHoldsCredit's answer; a file that does not exist holds none; a file that cannot be read counts as
// holding it (the notice errs toward saying so). No store read, no lock: a read-only check, as walletHoldsCredit is.
func walletHoldsUnrestoredCredit(wp string) bool {
	restored := readWalletRestored(wp, walletGeneration(wp))
	if len(restored) == 0 {
		return walletHoldsCredit(wp) // no record: today's answer
	}
	if _, err := os.Stat(wp); os.IsNotExist(err) {
		return false
	}
	w, err := loadWallet(wp)
	if err != nil {
		return true
	}
	for _, k := range walletTokenKeys(w) {
		if !restored[k] {
			return true
		}
	}
	return false
}
