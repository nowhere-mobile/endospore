package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Slice D (docs/owner-inbox-plan.md): the device-owner telephony inbox. An unbound SIM is the device owner's line
// (product-decisions.md 2026-09-01); its inbound calls, SMS and MMS are sealed to the device-owner key's PUBLIC half
// and read from an inbox behind the owner passphrase, kept in RAM until the owner clears them or the phone reboots
// (2026-09-24, 2026-09-27, 2026-09-30).
//
// Where before this slice an unbound arrival answered NONE and was dropped, sealArrival now seals it here. The store
// is $STATE/tel/owner, a sibling of the per-profile bound inbox ($STATE/tel/inbox): both live under the tel subtree
// that wipeSessionState spares, so no profile's create, login, logoff or delete touches it, and deleteSimBlobs is
// scoped to tel/inbox, so a SIM's unassign never removes an owner item either. Only CLEAR-OWNER-INBOX, a per-item
// DELETE-OWNER-ITEM, or the reboot (tmpfs) removes one -- exactly the 2026-09-24 rule ("unbound -- it shouldnt get
// wiped by any profile (only the owner or a reboot can clean it)").
//
// The seal uses the owner key's PUBLIC half only (owner_key.go keeps pub= in cleartext), so it never takes
// ownerKeyMu, never derives a key, and works while nobody is verified. Only an absent or unreadable key -- a device
// enrolled before the key existed and not yet verified, or a damaged file -- is an accepted loss, as the 2026-09-27
// decision allows. Reading an item back needs the private half, so the inbox verbs carry the owner passphrase and
// derive the key per call (there is no long-lived key in the daemon); the chooser holds the passphrase in owner mode.

// ownerInboxBase is the owner store dir. A var so tests can point it at a temp dir (mirrors telInboxBase).
var ownerInboxBase = filepath.Join(stateDirDefault, telStateSubdir, "owner")

// The telephony RAM budgets (Slice D, sized against the 256 MiB state tmpfs the wallet and the live session share;
// docs/backlog.md "Telephony records have no RAM budget ..."). BOTH inboxes -- the owner store and the bound store --
// have a soft line past which an MMS is kept without its media (sender, subject and time survive) and a hard line past
// which nothing is kept and the loss notice posts (docs/product-decisions.md, 2026-09-30, "two budgets"). Each is 12 /
// 16 MiB, so the ceiling of the two together is 32 MiB -- 12.5% of the 256 MiB state tmpfs (measured on lynx
// 2026-10-01, NWP-20261001-01) -- and a flood on one of the phone's numbers can never starve the wallet or a live
// session. Each budget weighs its own base. The old note that the bound soft-strip was "a bounded follow-on" is
// SUPERSEDED: the 2026-09-30 decision already answers it, and NWP-20261019-02 builds it (sealBoundCopy). The live
// mailbox row of a signed-in owner is never stripped; only the sealed copies waiting in the store are. Vars, not
// consts, only so a test can lower them to exercise the lines with small items; nothing at runtime writes them.
var (
	telOwnerBudgetSoft int64 = 12 << 20
	telOwnerBudgetHard int64 = 16 << 20
	telBoundBudgetSoft int64 = 12 << 20
	telBoundBudgetHard int64 = 16 << 20
)

// ownerItemName matches an owner item's file name: "<16 hex>.seal". The stem is the item id the inbox verbs use.
// Owner items are never SIM-tagged (unlike the bound inbox): nothing purges them by SIM, so there is no tag to carry.
var ownerItemName = regexp.MustCompile(`^([0-9a-f]{16})\.seal$`)
var reOwnerItemID = regexp.MustCompile(`^[0-9a-f]{16}$`)

// telStoreUsage sums the bytes of the published blobs under base (recursively): sealed ".seal" blobs AND the ".pend"
// copies bufferPending keeps for every live-delivered row, which sit in the same directories and hold the same
// tmpfs until the chooser acknowledges them -- left out, a flood while the chooser is not acknowledging would grow
// without limit. In-flight dotfile temps and anything else are ignored. The owner store has no ".pend" files. Used to
// weigh an arrival against a budget. A missing base is 0.
func telStoreUsage(base string) int64 {
	var total int64
	filepath.WalkDir(base, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		n := d.Name()
		if strings.HasPrefix(n, ".") || !(strings.HasSuffix(n, ".seal") || strings.HasSuffix(n, ".pend")) {
			return nil
		}
		if fi, e := d.Info(); e == nil {
			total += fi.Size()
		}
		return nil
	})
	return total
}

// telBudgetVerdict says how to treat a new sealed item of sz bytes given the store's current usage and its budget.
type telBudgetVerdict int

const (
	telBudgetOK    telBudgetVerdict = iota // seal it whole
	telBudgetStrip                         // over the soft line: seal an MMS without its media (keep from/subject/when)
	telBudgetFull                          // over the hard line: keep nothing, post the loss notice
)

// telBudget weighs an item: full when adding it would cross hard, strip when it would cross soft, else ok. Measured
// against the store's current on-disk usage so every record under the base (owner or bound) counts, not just this run.
func telBudget(base string, sz int64, soft, hard int64) telBudgetVerdict {
	used := telStoreUsage(base)
	switch {
	case used+sz > hard:
		return telBudgetFull
	case used+sz > soft:
		return telBudgetStrip
	default:
		return telBudgetOK
	}
}

// ownerPubForSeal returns the device-owner public key to seal an unbound arrival to, and whether one is available. A
// key that is absent, unreadable or newer-format cannot be sealed to -- the arrival is an accepted loss (NONE), as
// the 2026-09-27 decision allows for a device not yet verified after the key landed. A v2 file (a rewrap in flight)
// seals to its pub, which both wrappings share.
func ownerPubForSeal() (pub string, ok bool) {
	f, st, err := readOwnerKey()
	if err != nil || st != ownerKeyValid {
		return "", false
	}
	return f.pub, true
}

// bufferOwner writes one sealed blob (base64) into the owner store as "<rand>.seal", creating the dir on demand, via
// a dotfile + rename so a concurrent list never sees a half-written blob. Caller holds telMu.
func bufferOwner(sealedB64 string) error {
	if err := os.MkdirAll(ownerInboxBase, 0o700); err != nil {
		return err
	}
	name := randHex(8) + ".seal"
	return writeAtomic(filepath.Join(ownerInboxBase, "."+name), filepath.Join(ownerInboxBase, name), []byte(sealedB64))
}

// randHex is n random bytes as lower-case hex.
func randHex(n int) string {
	const hexd = "0123456789abcdef"
	b := randBytes(n)
	out := make([]byte, 2*n)
	for i, c := range b {
		out[2*i] = hexd[c>>4]
		out[2*i+1] = hexd[c&0xf]
	}
	return string(out)
}

// listOwnerSealed returns the owner store's sealed-blob paths, sorted. Skips dotfiles and non-.seal entries.
func listOwnerSealed() []string {
	ents, err := os.ReadDir(ownerInboxBase)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if e.IsDir() || !ownerItemName.MatchString(e.Name()) {
			continue
		}
		out = append(out, filepath.Join(ownerInboxBase, e.Name()))
	}
	sort.Strings(out)
	return out
}

// ownerItemID is the item id of a path ("<16 hex>" from "<16 hex>.seal"), or "" if the name is not an owner item.
func ownerItemID(path string) string {
	if m := ownerItemName.FindStringSubmatch(filepath.Base(path)); m != nil {
		return m[1]
	}
	return ""
}

// sealUnboundToOwner seals an unbound arrival to the device owner and returns the wire reply and the log verdict.
// Caller holds telMu. The seal uses only the owner public half; it never derives a key or takes ownerKeyMu.
//
//	OWNER  sealed to the owner inbox; the gate posts the unassigned-SIM notice
//	FULL   the owner inbox is at its hard budget; nothing kept, the gate posts "may not have been saved"
//	NONE   no owner key yet (device not verified since it landed): an accepted loss, as before this slice
//
// OWNER and NONE carry "number" when the owner's opt-in is on (unboundNoticeReply).
func sealUnboundToOwner(a *arrivalReq) (reply, verdict string) {
	pub, ok := ownerPubForSeal()
	if !ok {
		telClassNote(telClassOwnerNoKey)
		return unboundNoticeReply("NONE"), telVerdictUnbound
	}
	it := a.it
	// An MMS over the per-item cap keeps sender, subject and time without its media, as the bound path does
	// (sealBoundArrival): a large MMS on the owner's line is still learned, not dropped whole. Done before the budget
	// weigh so the RAM budget sees the stripped size, and so sealTelItem's over-cap error can never turn it into FULL.
	if a.verb == "SEAL-MMS" && telItemOversize(it) {
		it.Parts = nil
		it.Note = "too-large"
	}
	// Weigh the item; an MMS over the aggregate soft line is re-weighed stripped so the owner still learns it came.
	sz := int64(len(mustMarshalLen(it)))
	switch telBudget(ownerInboxBase, sz, telOwnerBudgetSoft, telOwnerBudgetHard) {
	case telBudgetFull:
		telClassNote(telClassOwnerFull)
		return "FULL\n", telVerdictOwnerFull
	case telBudgetStrip:
		if a.verb != "SEAL-MMS" {
			// A non-MMS over the soft line cannot shed media; if it would also cross hard it is already FULL above,
			// so here it still fits under hard -- keep it whole.
			break
		}
		it.Parts = nil
		it.Note = "too-large"
		if telBudget(ownerInboxBase, int64(len(mustMarshalLen(it))), telOwnerBudgetSoft, telOwnerBudgetHard) == telBudgetFull {
			telClassNote(telClassOwnerFull)
			return "FULL\n", telVerdictOwnerFull
		}
	}
	sealed, err := sealTelItem(pub, it)
	if err != nil {
		telClassNote(telClassOwnerFull) // a marshal failure; an over-cap MMS was already stripped above
		return "FULL\n", telVerdictOwnerFull
	}
	if err := bufferOwner(sealed); err != nil {
		telClassNote(telClassOwnerFull) // ENOSPC on the tmpfs behaves as a full store: no record, a loss notice
		return "FULL\n", telVerdictOwnerFull
	}
	return unboundNoticeReply("OWNER"), telVerdictOwner
}

// unboundNoticeReply is an OWNER or NONE reply: the word alone, or the word and "number" when the owner's opt-in
// (noticeNumberGet) shows the caller's number on the gate notice (h59 #13). OWNER and NONE carry the same token, so the
// notice never tells a kept arrival from an unkept one.
func unboundNoticeReply(word string) string {
	if noticeNumberGet() == "1" {
		return word + " number\n"
	}
	return word + "\n"
}

// mustMarshalLen marshals an item for a size check; a marshal error yields an over-cap length so the item is refused.
func mustMarshalLen(it telItem) []byte {
	b, err := json.Marshal(it)
	if err != nil {
		return make([]byte, maxTelItemBytes+1)
	}
	return b
}

// ---- the owner-inbox verbs (gate-only, on telMu) --------------------------------------------------------------

// ownerInboxCmd reports whether handleOwnerInbox serves a verb.
func ownerInboxCmd(name string) bool {
	switch name {
	case "GET-OWNER-INBOX", "READ-OWNER-ITEM", "DELETE-OWNER-ITEM", "CLEAR-OWNER-INBOX":
		return true
	}
	return false
}

// ownerInboxRow is the content-minimal projection the LIST verb returns per item: everything the chooser renders a
// row from, with an MMS's media parts replaced by their count (READ-OWNER-ITEM fetches the full item, media and all).
type ownerInboxRow struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	SubID    int    `json:"sub_id"`
	From     string `json:"from"`
	When     int64  `json:"when"`
	Body     string `json:"body,omitempty"`
	CallType int    `json:"call_type,omitempty"`
	DurSec   int    `json:"dur_sec,omitempty"`
	Subject  string `json:"subject,omitempty"`
	NParts   int    `json:"nparts,omitempty"`
	Note     string `json:"note,omitempty"`
}

func ownerInboxRowOf(id string, it telItem) ownerInboxRow {
	return ownerInboxRow{
		ID: id, Kind: it.Kind, SubID: it.SubID, From: it.From, When: it.When,
		Body: it.Body, CallType: it.CallType, DurSec: it.DurSec,
		Subject: it.Subject, NParts: len(it.Parts), Note: it.Note,
	}
}

// handleOwnerInbox serves the owner-inbox verbs. Like handleOwnerKey it refuses any caller but the user-0 gate before
// it reads the request, and the refusal never depends on whether any item exists. GET and READ carry the owner
// passphrase (three lines, as the owner-key request) and derive the key to open items; DELETE and CLEAR carry only an
// item id, if any, and need no key. The owner key is derived OUTSIDE telMu (a 64 MiB Argon2id must never block an
// arrival); telMu is held only for the local file work. The body of an item never reaches a log.
func handleOwnerInbox(conn net.Conn, r *bufio.Reader, name string) {
	if !ownerCallerOK(ownerPeerUID(conn)) {
		fmt.Fprint(os.Stderr, "[logind] owner-inbox refused (caller is not the user-0 gate)\n")
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	switch name {
	case "GET-OWNER-INBOX":
		serveOwnerInboxList(conn, r)
	case "READ-OWNER-ITEM":
		serveOwnerInboxRead(conn, r)
	case "DELETE-OWNER-ITEM":
		serveOwnerInboxDelete(conn, r)
	case "CLEAR-OWNER-INBOX":
		serveOwnerInboxClear(conn)
	}
}

// ownerKeyFromRequest reads the three owner-key request lines (v1, pepper, pass), opens the owner key, and returns the
// private half. It opens either wrapping of a v2 key file (NWP-20261021-11), the new first. The caller clears priv. A missing or unreadable key, or a passphrase that does not open it, is "" nil:
// the inbox then reads as empty, which is also what a wrong passphrase yields -- the inbox never reveals that it holds
// anything to a caller who cannot open it.
func ownerKeyFromRequest(r *bufio.Reader) (priv []byte, err error) {
	pepper, pass, err := readOwnerKeyRequest(r)
	if err != nil {
		return nil, err
	}
	defer clear(pass)
	defer clear(pepper)
	f, st, rerr := readOwnerKey()
	if rerr != nil || st != ownerKeyValid {
		return nil, nil
	}
	priv, _, _, ok := ownerKeyOpenAny(f.wraps(), pass, pepper)
	if !ok {
		return nil, nil
	}
	return priv, nil
}

// serveOwnerInboxList opens every owner item and writes one base64 JSON ownerInboxRow per line after "OK". A blob
// that will not read or open is skipped (it cannot be shown; the reboot takes it). NONE when the key does not open or
// nothing is buffered -- indistinguishable, so a wrong passphrase cannot learn the inbox holds anything.
func serveOwnerInboxList(conn net.Conn, r *bufio.Reader) {
	priv, err := ownerKeyFromRequest(r)
	if err != nil {
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	if priv == nil {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	defer clear(priv)
	var lines []string
	underTelMu(func() {
		for _, p := range listOwnerSealed() {
			b, e := os.ReadFile(p)
			if e != nil {
				continue
			}
			it, e := openTelItem(priv, string(b))
			if e != nil {
				continue
			}
			row := ownerInboxRowOf(ownerItemID(p), it)
			rb, e := json.Marshal(row)
			if e != nil {
				continue
			}
			lines = append(lines, base64.StdEncoding.EncodeToString(rb))
		}
	})
	if len(lines) == 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprint(conn, "OK\n")
	for _, l := range lines {
		fmt.Fprintf(conn, "%s\n", l)
	}
}

// serveOwnerInboxRead opens one item by id and writes its full telItem (media included) as one base64 JSON line after
// "OK". NONE when the key does not open, the id is unknown, or the blob will not open.
func serveOwnerInboxRead(conn net.Conn, r *bufio.Reader) {
	priv, perr := ownerKeyFromRequest(r)
	if perr != nil {
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	idLines, err := readLines(r, 1)
	if err != nil {
		clear(priv)
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	id := idLines[0]
	if priv == nil || !reOwnerItemID.MatchString(id) {
		clear(priv)
		fmt.Fprint(conn, "NONE\n")
		return
	}
	defer clear(priv)
	var blob []byte
	underTelMu(func() {
		if b, e := os.ReadFile(filepath.Join(ownerInboxBase, id+".seal")); e == nil {
			blob = b
		}
	})
	if blob == nil {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	it, e := openTelItem(priv, string(blob))
	if e != nil {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	rb, e := json.Marshal(it)
	if e != nil {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "OK\n%s\n", base64.StdEncoding.EncodeToString(rb))
}

// serveOwnerInboxDelete removes one owner item by id. No key needed: deleting a sealed file never opens it. OK whether
// or not the id was present (a delete the owner already made, or a reboot took, is not an error).
func serveOwnerInboxDelete(conn net.Conn, r *bufio.Reader) {
	idLines, err := readLines(r, 1)
	if err != nil {
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	id := idLines[0]
	if !reOwnerItemID.MatchString(id) {
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	underTelMu(func() { os.Remove(filepath.Join(ownerInboxBase, id+".seal")) })
	fmt.Fprint(conn, "OK\n")
}

// serveOwnerInboxClear removes every owner item. The chooser additionally clears the unassigned-SIM gate notices
// (decided 2026-09-27). No key needed.
func serveOwnerInboxClear(conn net.Conn) {
	underTelMu(func() {
		for _, p := range listOwnerSealed() {
			os.Remove(p)
		}
	})
	fmt.Fprint(conn, "OK\n")
}
