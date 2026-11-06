package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// NWP-20261006-05 -- a record's sealed copy is kept until the session has INSERTED it (Chester, 2026-10-06, "go with
// b": option (b) of the rows "Rows left in a session's mailbox when the session ends are never returned to the sealed
// inbox" and "A sealed telephony record is dropped at the hand-off, before the chooser inserts it").
//
// Before this, a sealed copy was deleted the moment its plaintext row was written to the session's mailbox
// (stageTelInbox -> dropSealed), and a live arrival for a signed-in owner was never sealed at all (deliverToOwners).
// So a session that ended before its chooser had inserted a row -- a logoff, a wipe, a crash, a lost kick -- lost
// that row for good: the mailbox is plaintext on the tmpfs and names no profile, so nothing could return it.
//
// Now a handed-off copy becomes PENDING for the session it was handed to: renamed "<tag>.<rand>.<uid>.<kh>.pend"
// (or "<rand>.<uid>.<kh>.pend" untagged), where kh is a hash of the uid and the row's key (kind + arrival ms, the pair
// the chooser dedups on). The chooser acknowledges the rows that landed (ACK-TELROWS), and only those copies are
// deleted. A copy still pending for a session that has ended is staged again at the profile's next sign-in. The
// key lives in the NAME, not in daemon memory, so an acknowledgement still finds its copy after a daemon restart.
//
// ⚠ What (b) costs, which was NOT put to Chester when he chose it (raised with him by this slice): a text that was
// inserted but whose acknowledgement never arrived comes back at the next sign-in, and shows twice. A call dedups
// itself there (the call log read-back is reliable); an SMS cannot (READ_SMS is ceded to Messaging). The chooser
// acknowledges each text as soon as the pass that inserted it ends, so this needs the session to end inside one
// local round trip, or the acknowledgement to be lost -- against, before, the certain loss of every row not yet
// inserted when a session ended.
// CLOSED by NWP-20261006-07 (Chester, 2026-10-06, "lets make a resent text not show twice"): the chooser now reads
// its own Messages back (TelIngest.ensureSmsRead) and finds a text or MMS it already inserted, so a redelivered row is
// not inserted again. A session where that read grant fails falls back to the window above.

// pendName matches a pending copy: optional SIM tag, the blob's random id, the session uid, the key hash.
var pendName = regexp.MustCompile(`^(?:([0-9a-f]{16})\.)?([0-9a-f]{16})\.([0-9]+)\.([0-9a-f]{16})\.pend$`)

// itemRowKey is the key a row carries on the wire: its first two tokens, kind and arrival ms (serializeTelIngest).
func itemRowKey(it telItem) string { return it.Kind + " " + strconv.FormatInt(it.When, 10) }

// rowKeyHash binds a row key to the session it was handed to.
func rowKeyHash(uid, key string) string {
	h := sha256.Sum256([]byte(uid + "\x00" + key))
	return hex.EncodeToString(h[:8])
}

// pendingPath is where blob p goes when it is handed to session uid as the row with this key. p is either a sealed
// blob ("[tag.]rand.seal") or a pending one for an earlier session ("[tag.]rand.uid.kh.pend"); the tag and the
// random id are kept, so an unassign still finds it by tag.
func pendingPath(p, uid, key string) string {
	dir, base := filepath.Split(p)
	tag, id := "", ""
	if m := pendName.FindStringSubmatch(base); m != nil {
		tag, id = m[1], m[2]
	} else if m := sealedName.FindStringSubmatch(base); m != nil {
		tag, id = m[1], strings.TrimSuffix(strings.TrimPrefix(base, m[1]+"."), ".seal")
	} else {
		id = strings.TrimSuffix(base, ".seal")
	}
	name := id + "." + uid + "." + rowKeyHash(uid, key) + ".pend"
	if tag != "" {
		name = tag + "." + name
	}
	return filepath.Join(dir, name)
}

// pendingUID is the session a pending copy was handed to, "" for anything else.
func pendingUID(p string) string {
	if m := pendName.FindStringSubmatch(filepath.Base(p)); m != nil {
		return m[3]
	}
	return ""
}

// listPending returns the profile's pending copies, sorted.
func listPending(profileRef string) []string {
	ents, err := os.ReadDir(telInboxDir(profileRef))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && pendName.MatchString(e.Name()) {
			out = append(out, filepath.Join(telInboxDir(profileRef), e.Name()))
		}
	}
	sort.Strings(out)
	return out
}

// bufferPending keeps a sealed copy of a row just appended LIVE to session uid's mailbox, pending until the chooser
// acknowledges it. Same budget and publish as bufferSealed.
func bufferPending(profileRef, tag, uid, key, sealedB64 string) error {
	if telStoreUsage(telInboxBase)+int64(len(sealedB64)) > telBoundBudgetHard {
		telClassNote(telClassBoundFull)
		return errTelBoundFull
	}
	dir := telInboxDir(profileRef)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	base := hex.EncodeToString(randBytes(8)) + ".seal"
	if isSimTag(tag) {
		base = tag + "." + base
	}
	dst := pendingPath(filepath.Join(dir, base), uid, key)
	return writeAtomic(filepath.Join(dir, "."+filepath.Base(dst)), dst, []byte(sealedB64))
}

// ackPending deletes the pending copies of the rows session uid has inserted, in whichever profile's buffer they
// sit, then any buffer dir that leaves empty. Returns how many it deleted.
func ackPending(uid string, keys []string) int {
	if uid == "" || len(keys) == 0 {
		return 0
	}
	want := map[string]bool{}
	for _, k := range keys {
		if k = strings.TrimSpace(k); k != "" {
			want[rowKeyHash(uid, k)] = true
		}
	}
	dirs, err := os.ReadDir(telInboxBase)
	if err != nil {
		return 0
	}
	n := 0
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		dir := filepath.Join(telInboxBase, d.Name())
		ents, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range ents {
			m := pendName.FindStringSubmatch(e.Name())
			if m == nil || m[3] != uid || !want[m[4]] {
				continue
			}
			if os.Remove(filepath.Join(dir, e.Name())) == nil {
				n++
			}
		}
		os.Remove(dir) // non-recursive: only when this emptied it
	}
	return n
}

// mailboxKeys are the row keys still waiting in session uid's mailbox (unclaimed).
func mailboxKeys(uid string) map[string]bool {
	out := map[string]bool{}
	for _, p := range mailboxFiles(uid) {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			if f := strings.Fields(line); len(f) >= 2 {
				out[f[0]+" "+f[1]] = true
			}
		}
	}
	return out
}
