package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// #135 B2 ingest hand-off (docs/telephony-owner-mode.md), delivery v2. At login or cold-lock resume the agent
// decrypts this profile's sealed telephony inbox (it holds DK) and serializes the cleartext items to a per-uid
// mailbox on the RAM tmpfs (0600). The roamed user's OWN chooser (TelIngest) takes the mailbox over the socket
// (GET-TELINGEST, peer-authorized by uid) and inserts the rows into its own providers; live arrivals for a
// signed-in owner are appended to the same mailbox. (The old roamd `telingest` op that content-inserted from
// su:s0 is retired.) The plaintext hand-off is RAM-only and root-only, the same transient-plaintext posture as
// the roam-in restore that untars app data into /data/user/N right alongside it.

// telIngestBase holds the per-uid mailboxes: the telephony subtree of the state tmpfs, which wipeSessionState
// spares (telephony_inbox.go). A var so tests can redirect it. The dir does not exist until the first mailbox
// is written after boot, so every writer creates it (telIngestDir).
var telIngestBase = filepath.Join(stateDirDefault, telStateSubdir)

// telIngestDir makes sure the mailbox dir exists. Before NWP-20260924-04 the mailboxes sat in the tmpfs ROOT,
// which always exists; the telephony subtree is created on demand.
func telIngestDir() error {
	return os.MkdirAll(telIngestBase, 0o700)
}

// telIngestPath is uid's mailbox for the SIM with this tag: "telingest.<uid>.<tag>" (NWP-20260924-07, so an unassign
// can delete one SIM's rows), or the bare "telingest.<uid>" for an empty tag -- the rows whose SIM is unknown, which
// an unassign never deletes. The chooser never sees a path: GET-TELINGEST serves every file of the uid as one reply.
func telIngestPath(uid, tag string) string {
	if isSimTag(tag) {
		return filepath.Join(telIngestBase, "telingest."+uid+"."+tag)
	}
	return filepath.Join(telIngestBase, "telingest."+uid)
}

// mailboxFiles lists uid's mailbox files that exist: the bare one first, then the per-SIM ones in tag order. Names
// are matched exactly, so uid 1 never takes uid 10's files, and a ".tmp" (the temp file of the atomic roam-in
// write NWP-20260927-09 retired) or any other suffix is not a mailbox.
func mailboxFiles(uid string) []string {
	ents, err := os.ReadDir(telIngestBase)
	if err != nil {
		return nil
	}
	bare := "telingest." + uid
	var tagged []string
	var out []string
	for _, e := range ents {
		if !e.Type().IsRegular() {
			continue
		}
		n := e.Name()
		if n == bare {
			out = append(out, filepath.Join(telIngestBase, n))
		} else if strings.HasPrefix(n, bare+".") && isSimTag(strings.TrimPrefix(n, bare+".")) {
			tagged = append(tagged, filepath.Join(telIngestBase, n))
		}
	}
	sort.Strings(tagged)
	return append(out, tagged...)
}

// removeMailboxes deletes every mailbox file of uid (the deleted profile's session, or a fresh roam-in's stale
// leftovers). Returns the first error.
func removeMailboxes(uid string) error {
	forgetClaimedTags(uid) // NWP-20261005-15
	var first error
	for _, p := range mailboxFiles(uid) {
		if err := os.Remove(p); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// anyMailboxName matches every mailbox file and captures its uid: the bare per-uid file, a per-SIM one, and the
// ".tmp" an older daemon's atomic write could leave.
var anyMailboxName = regexp.MustCompile(`^telingest\.([0-9]+)(\.[0-9a-f]{16})?(\.tmp)?$`)

// sweepGoneMailboxes deletes the mailboxes of every uid whose Android user no longer exists, and returns how many uids
// it cleared. NWP-20261006-14: a session's mailbox is PLAINTEXT and names no profile, and it outlived every end of
// its session until reboot -- logout, a wipe, a supersede, the #73 sweep, a sign-in that failed after the agent said
// OK (the chooser removes that user without a CLEAN-STORAGE), and a departing chooser's RESTAGE after its delete. Its
// rows are redundant since NWP-20261006-05: each one handed to a session keeps a sealed copy, pending, which the
// profile's next sign-in stages again; a row whose copy could not be written could never have landed from here
// either. So a mailbox whose user is gone is only plaintext at rest. Called at every reap (CLEAN-STORAGE) and at
// every sign-in's bring-up, so whatever end a session took, its mailbox goes at the next of those. Caller holds telMu.
func sweepGoneMailboxes() int {
	ents, err := os.ReadDir(telIngestBase)
	if err != nil {
		return 0
	}
	gone := map[string]bool{}
	for _, e := range ents {
		if m := anyMailboxName.FindStringSubmatch(e.Name()); m != nil && androidUserGone(m[1]) {
			gone[m[1]] = true
		}
	}
	for uid := range gone {
		removeMailboxes(uid)
		for _, e := range ents { // and the .tmp leftovers, which mailboxFiles does not list
			if m := anyMailboxName.FindStringSubmatch(e.Name()); m != nil && m[1] == uid && m[3] != "" {
				os.Remove(filepath.Join(telIngestBase, e.Name()))
			}
		}
	}
	return len(gone)
}

// simMailboxName matches any uid's mailbox for one SIM, and the ".tmp" an older daemon's atomic roam-in write could
// leave beside it (a hot-patched agent meets that daemon's tmpfs in the same boot).
var simMailboxName = regexp.MustCompile(`^telingest\.[0-9]+\.([0-9a-f]{16})(\.tmp)?$`)

// deleteSimMailboxes deletes every uid's mailbox rows that came in on the SIM with this tag (an unassign). The bare
// per-uid files are never touched. Returns how many files it removed and the first error.
func deleteSimMailboxes(tag string) (int, error) {
	if !isSimTag(tag) {
		return 0, nil
	}
	ents, err := os.ReadDir(telIngestBase)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	n := 0
	var first error
	for _, e := range ents {
		m := simMailboxName.FindStringSubmatch(e.Name())
		if m == nil || m[1] != tag {
			continue
		}
		if err := os.Remove(filepath.Join(telIngestBase, e.Name())); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		n++
	}
	return n, first
}

// serializeTelIngest renders items as one line each:
//
//	<kind> <when_ms> <call_type> <dur_sec> <from_b64> <body_b64>
//
// from + body are base64 so arbitrary text (spaces, newlines, '|', quotes) survives as a single
// whitespace-free token for a space-splitting reader. An EMPTY from/body serializes as the sentinel
// "-" (never valid standard base64), NOT as an empty token: a call row always has an empty body, and
// an empty trailing token does not survive the Java reader (DaemonSocket line-trims the reply and
// String.split(" ") drops trailing empties) -- the review catch that silently dropped every call row.
// The sentinel keeps the token count fixed at 6 for every row and every reader.
//
// NWP-20260924-07: a CALL row's body slot carries its SIM tag, "-<tag>", instead of the plain "-". A call has no
// body, and the chooser never reads that slot for a call (TelIngest.deliver reads f[5] only for an SMS) but echoes
// it back verbatim when it re-stages a call row (RESTAGE-TELINGEST) -- so the tag survives the round trip, and a
// re-staged row returns to its SIM's mailbox, or is dropped if that SIM was unassigned meanwhile.
//
// NWP-20261130-01: an SMS or MMS row carries its tag too, in a slot of its own, "sim:<tag>", directly after the row's
// fixed fields and before any retry token (simSlot). The session's chooser files the row under that SIM's subscription:
// on GrapheneOS 2026110200 the provider shows a session no sub_id=-1 row (docs/product-decisions.md, 2026-11-06). A
// row with no slot stays valid (the chooser files it under sub_id=-1), and a reader that predates the slot reads only
// the fixed fields. A call row keeps its body slot and never has this one. The sealed blob needs no change: its tag
// is in its file name (blobTag), and a row is rendered from that.
func serializeTelIngest(items []telItem, tag string) string {
	var sb strings.Builder
	for _, it := range items {
		// #150 P4: an MMS can't fit the fixed 6-token sms/call line -- its multipart body (subject + binary
		// parts) has no place in it. Serialize the whole telItem as ONE base64 JSON token:
		//   "mms <when_ms> <telItem_json_b64>"
		// The reader (TelIngest.deliver) detects f[0]=="mms", base64-decodes + JSON-parses f[2], and does the
		// multi-table content://mms insert. Stays line-based so GET-TELINGEST serves it like any other row.
		if it.Kind == "mms" {
			j, err := json.Marshal(it)
			if err != nil {
				continue // a telItem that won't marshal is dropped, not fatal (best-effort delivery)
			}
			sb.WriteString("mms ")
			sb.WriteString(strconv.FormatInt(it.When, 10))
			sb.WriteByte(' ')
			sb.WriteString(base64.StdEncoding.EncodeToString(j))
			sb.WriteString(simSlot(tag))
			sb.WriteByte('\n')
			continue
		}
		sb.WriteString(it.Kind)
		sb.WriteByte(' ')
		sb.WriteString(strconv.FormatInt(it.When, 10))
		sb.WriteByte(' ')
		sb.WriteString(strconv.Itoa(it.CallType))
		sb.WriteByte(' ')
		sb.WriteString(strconv.Itoa(it.DurSec))
		sb.WriteByte(' ')
		sb.WriteString(b64tok(it.From))
		sb.WriteByte(' ')
		if it.Kind == "call" {
			sb.WriteString("-")
			if isSimTag(tag) {
				sb.WriteString(tag)
			}
		} else {
			sb.WriteString(b64tok(it.Body))
			sb.WriteString(simSlot(tag))
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}

// b64tok encodes a wire token: base64 of the value, or the "-" sentinel for empty (see serializeTelIngest).
func b64tok(s string) string {
	if s == "" {
		return "-"
	}
	return base64.StdEncoding.EncodeToString([]byte(s))
}

// simSlotPrefix marks the SIM tag's own slot in an SMS or MMS row. No base64 token, number or "-" sentinel starts
// with it, so it also tells a tagged row from an untagged one with a retry token.
const simSlotPrefix = "sim:"

// simSlot is the token an SMS or MMS row appends for its SIM, with its separating space: nothing for an empty tag.
func simSlot(tag string) string {
	if !isSimTag(tag) {
		return ""
	}
	return " " + simSlotPrefix + tag
}

// rowTag is the SIM tag a serialized row carries in-band: a call row's body slot "-<tag>", or the "sim:<tag>" slot of
// an SMS row (f[6]) or an MMS row (f[3]), at exactly that position. "" for anything else, including an untagged "-".
// TelSub.rowTag is the chooser's copy of the SMS and MMS rule.
func rowTag(row string) string {
	f := strings.Fields(row)
	var t string
	switch {
	case len(f) >= 6 && f[0] == "call" && strings.HasPrefix(f[5], "-"):
		t = f[5][1:]
	case len(f) >= 7 && f[0] == "sms" && strings.HasPrefix(f[6], simSlotPrefix):
		t = f[6][len(simSlotPrefix):]
	case len(f) >= 4 && f[0] == "mms" && strings.HasPrefix(f[3], simSlotPrefix):
		t = f[3][len(simSlotPrefix):]
	}
	if isSimTag(t) {
		return t
	}
	return ""
}

// appendTelIngest adds ONE cleartext row to the live session's ingest hand-off (#149 live delivery). A
// text/call for a bound owner who is ALREADY logged in is staged straight here -- it is plaintext at the
// gate, so no seal/decrypt is needed -- and the roamed chooser is kicked to insert it into its own
// providers immediately, instead of waiting for that owner's next login. APPEND, like every mailbox write
// since NWP-20260927-09, so back-to-back live arrivals don't clobber each other before the chooser claims the file.
func appendTelIngest(uid, tag string, it telItem) error {
	return appendMailbox(uid, tag, serializeTelIngest([]telItem{it}, tag))
}

// appendTelIngestRaw appends ONE already-serialized row line (the exact wire form GET-TELINGEST serves,
// optionally with a trailing retry-count token) back onto the caller's mailbox. #135 Part 3: the roamed
// chooser RE-STAGES a call row it could not persist this delivery run, so a later kick (a cold-lock RESUME
// re-kick, #385) retries it instead of log-and-dropping it. APPEND (like appendTelIngest) so a concurrent
// live SEAL-TEL append is not clobbered; the chooser caps retries via the row's trailing token so a
// persistently-failing row can't loop.
func appendTelIngestRaw(uid, line string) error {
	if !strings.HasSuffix(line, "\n") {
		line += "\n"
	}
	return appendMailbox(uid, rowTag(line), line)
}

// restageTelIngest serves RESTAGE-TELINGEST: it puts a row the chooser could not persist back into its SIM's
// mailbox -- unless that SIM is no longer bound, which means it was unassigned while the chooser held the row. The
// unassign deleted everything else that came in on that SIM, so the row is dropped too (dropped=true) rather than
// resurrected. A row with no in-row tag goes to the bare mailbox, as before.
func restageTelIngest(uid, row string) (dropped bool, err error) {
	t := rowTag(row)
	if t == "" {
		// NWP-20261005-15: an SMS or MMS row with no in-row tag (one from before NWP-20261130-01, or one an older
		// chooser re-staged without its slot); its SIM is the one whose mailbox it was claimed from. Without this a
		// re-staged SMS went to the bare mailbox, which an unassign never deletes -- against the decision that an
		// unbind deletes that line's undelivered texts (2026-09-24).
		t = takeClaimedTag(uid, row)
	}
	if t != "" && simUnboundNow(t) { // NWP-20260930-04: a damaged bindings.conf keeps the row
		return true, nil
	}
	if !strings.HasSuffix(row, "\n") {
		row += "\n"
	}
	return false, appendMailbox(uid, t, row)
}

// NWP-20261005-15: the SIM of every claimed row that carries no in-row tag, so restageTelIngest can put it back
// where it came from. Keyed by uid plus the row's kind and arrival ms (its first two tokens -- the pair the chooser
// dedups on). An entry is taken on use and dropped with the uid's mailboxes; a row claimed and delivered leaves one
// small entry until then.
var (
	claimedTagsMu sync.Mutex
	claimedTags   = map[string]string{}
)

func claimedKey(uid, row string) string {
	f := strings.Fields(row)
	if len(f) < 2 {
		return ""
	}
	return uid + "\x00" + f[0] + " " + f[1]
}

// noteClaimedTags records tag for every row of one claimed mailbox file that a re-stage can bring back without an
// in-row tag: every row except a tagged call. A tagged SMS or MMS row counts, because a chooser that predates
// NWP-20261130-01 re-stages it without its slot.
func noteClaimedTags(uid, tag string, b []byte) {
	if !isSimTag(tag) {
		return
	}
	claimedTagsMu.Lock()
	defer claimedTagsMu.Unlock()
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "call ") && rowTag(line) != "" {
			continue
		}
		if k := claimedKey(uid, line); k != "" {
			claimedTags[k] = tag
		}
	}
}

func takeClaimedTag(uid, row string) string {
	k := claimedKey(uid, row)
	if k == "" {
		return ""
	}
	claimedTagsMu.Lock()
	defer claimedTagsMu.Unlock()
	t := claimedTags[k]
	delete(claimedTags, k)
	return t
}

func forgetClaimedTags(uid string) {
	claimedTagsMu.Lock()
	defer claimedTagsMu.Unlock()
	for k := range claimedTags {
		if strings.HasPrefix(k, uid+"\x00") {
			delete(claimedTags, k)
		}
	}
}

// appendTelIngestBatch appends a whole batch, so rows already waiting in the mailbox -- a live arrival, or a
// row the chooser re-staged for retry -- survive. Every staging uses it: a resume since NWP-20260924-04 (the old
// overwrite there destroyed exactly the re-staged rows the resume re-kick exists to retry), and a roam-in since
// NWP-20260927-09 (an arrival can now queue a row for the session between its marker and its staging).
func appendTelIngestBatch(uid, tag string, items []telItem) error {
	return appendMailbox(uid, tag, serializeTelIngest(items, tag))
}

// telAppendWrite is the one write appendMailbox makes; a var so a test can inject a short write.
var telAppendWrite = func(fh *os.File, s string) (int, error) { return fh.WriteString(s) }

// appendMailbox is every append to a mailbox: ONE O_APPEND write, all or nothing. A short write (ENOSPC on
// the tmpfs) is truncated back to the size the mailbox had, so no unterminated row is left for the next
// append to glue onto, and a caller that keeps its sealed copy on error (SEAL-TEL's live path, a resume's
// staging) does not deliver the half that landed a second time. If the rollback itself fails, the error says
// so. Safe because every mailbox writer and claimer holds telMu (telephony_lock.go).
func appendMailbox(uid, tag, s string) error {
	if err := telIngestDir(); err != nil {
		return err
	}
	fh, err := os.OpenFile(telIngestPath(uid, tag), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	fi, err := fh.Stat()
	if err != nil {
		fh.Close()
		return err
	}
	_, werr := telAppendWrite(fh, s)
	if werr != nil {
		if terr := fh.Truncate(fi.Size()); terr != nil {
			werr = fmt.Errorf("%v; rollback failed, the mailbox holds a partial write: %v", werr, terr)
		}
	}
	if cerr := fh.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// stageTelInbox hands a profile's sealed telephony to its session: decrypt, append the hand-off, and only then
// drop the blobs that were handed off. It always APPENDS (NWP-20260927-09): the mailbox may already hold rows for
// the same session -- an arrival queued since the session's marker, or a row the chooser re-staged -- and a roam-in's
// stale leftovers are removed before its marker instead (beginTelStaging). It works per SIM (NWP-20260924-07): a SIM
// whose hand-off fails keeps its sealed copies for the next delivery, and the SIMs handed off are dropped. Returns how
// many items were staged, and an error naming how many SIMs failed, with no SIM tag in it (telErrLine). Caller holds
// telMu (stageTelInboxLocked).
func stageTelInbox(v *vault, dk []byte, profileRef, uid string) (int, error) {
	// Non-recursive, on every exit: fails harmlessly while any blob remains (one that would not open, or a failed
	// hand-off's). An empty per-profile dir left behind -- including one a failed arrival created -- would carry
	// that time in its mtime until the reboot.
	defer os.Remove(telInboxDir(profileRef))
	items, opened := readTelInbox(v, dk, profileRef)
	// NWP-20261006-05: a copy pending for THIS session whose row still waits in its mailbox is already on its way (a
	// resume of the same session); staging it again would queue it twice. One pending for an ENDED session, or for this
	// one but no longer queued (claimed and never acknowledged), is staged again.
	queued := mailboxKeys(uid)
	keepI := 0
	for i := range items {
		if pendingUID(opened[i]) == uid && queued[itemRowKey(items[i])] {
			continue
		}
		items[keepI], opened[keepI] = items[i], opened[i]
		keepI++
	}
	items, opened = items[:keepI], opened[:keepI]
	if len(items) == 0 {
		return 0, nil
	}
	// NWP-20260924-07: one mailbox per SIM, so write and drop PER TAG. A failure on one SIM keeps exactly that
	// SIM's sealed copies; the others are handed off and dropped, not written twice by the next delivery.
	groups := map[string][]int{}
	var tags []string
	for i := range items {
		t := blobTag(opened[i])
		if _, ok := groups[t]; !ok {
			tags = append(tags, t)
		}
		groups[t] = append(groups[t], i)
	}
	sort.Strings(tags)
	staged := 0
	var errs []string
	for _, t := range tags {
		its := make([]telItem, 0, len(groups[t]))
		paths := make([]string, 0, len(groups[t]))
		for _, i := range groups[t] {
			its = append(its, items[i])
			paths = append(paths, opened[i])
		}
		if err := appendTelIngestBatch(uid, t, its); err != nil {
			errs = append(errs, telErrLine(err))
			continue
		}
		// NWP-20261006-05: not dropped -- kept, pending for this session, until the chooser acknowledges the row.
		for k, p := range paths {
			if np := pendingPath(p, uid, itemRowKey(its[k])); np != p {
				os.Rename(p, np)
			}
		}
		staged += len(its)
	}
	if len(errs) > 0 {
		return staged, fmt.Errorf("%d of %d SIM(s) not handed off: %s", len(errs), len(tags), strings.Join(errs, "; "))
	}
	return staged, nil
}

// mailboxTagInPath finds a per-SIM mailbox's tag in a file path.
var mailboxTagInPath = regexp.MustCompile(`(telingest\.[0-9]+)\.[0-9a-f]{16}`)

// telErrLine renders a staging error for login.log with every mailbox's SIM tag replaced. A failed file operation's
// error names its path, a per-SIM mailbox's path ends in the tag, and a tag is a stable name for the SIM that is
// never logged (simtag.go) -- login.log also travels in an issue report, whose scrub would not catch it.
func telErrLine(err error) string {
	return mailboxTagInPath.ReplaceAllString(err.Error(), "$1.<sim>")
}

// claimTelIngest TAKES every staged row of uid -- all its mailbox files, bare first then per SIM -- and returns them
// as one reply (nil, nil when nothing is staged). Each file is read and then removed. That is safe without the old
// rename-aside because GET-TELINGEST and every mailbox writer hold telMu (telephony_lock.go),
// so no append can land between the read and the remove -- the #149 lost-append race cannot occur -- and it leaves
// no ".claim.N" orphan behind on a crash. A file that will not read, or will not go, is left in place and NOT
// served, so the next claim takes it once rather than serving its rows twice; a file that does not end in a
// newline (a rollback that itself failed) gets one, so its last row is not glued onto the next file's first.
func claimTelIngest(uid string) ([]byte, error) {
	var out []byte
	var first error
	for _, p := range mailboxFiles(uid) {
		b, err := os.ReadFile(p)
		if err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		if err := os.Remove(p); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		if len(b) > 0 && b[len(b)-1] != '\n' {
			b = append(b, '\n')
		}
		noteClaimedTags(uid, strings.TrimPrefix(filepath.Base(p), "telingest."+uid+"."), b) // NWP-20261005-15
		out = append(out, b...)
	}
	return out, first
}
