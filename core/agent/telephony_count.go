package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// NWP-20261017-07 -- how many telephony records a reboot would destroy. Records are RAM-only under the state tmpfs, so
// every daemon reboot fallback loses whatever the profiles have not yet had inserted; this is the one number the
// fallbacks consult before they reboot (to retry or hold first) and log when they reboot anyway.
//
// CONTENT-FREE: it reads directory entry NAMES and the first two fields of each mailbox row. The kind and the arrival
// time are read only to form the key hash and are not kept or returned; no body, number, ref or profile name is
// returned or retained either, so the count can be logged after the reap's log_scrub.

// mailboxName matches a live mailbox file: "telingest.<uid>" or "telingest.<uid>.<sim tag>". A ".tmp" never matches.
// Capture 1 is the session uid, capture 2 the SIM tag.
var mailboxName = regexp.MustCompile(`^telingest\.([0-9]+)(?:\.([^.]+))?$`)

// telPendingCount counts pending telephony records: the sealed (.seal) and pending (.pend) copies in every
// per-profile inbox dir, the owner-inbox items, and the rows of every live mailbox file. Since NWP-20261006-05 a record
// handed to a session exists twice until the chooser acknowledges inserting it: as the plaintext row in that session's
// mailbox and as a pending (.pend) copy named for the session uid and rowKeyHash(uid, row key). Those are ONE record,
// so a row whose (mailbox uid, key hash) matches a counted .pend is not counted again. A row with fewer than two
// fields cannot be paired and counts; a trailing segment with no newline is not a row. A directory that does not
// exist counts zero (the subtree is created by the first write after boot); any other read failure is an error, never
// a quiet zero -- a caller that cannot tell must treat the answer as "pending".
func telPendingCount() (n int, err error) {
	dirs, err := os.ReadDir(telInboxBase)
	if err != nil && !os.IsNotExist(err) {
		return 0, err
	}
	type pendKey struct{ uid, kh string }
	pending := map[pendKey]bool{}
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		ents, e := os.ReadDir(filepath.Join(telInboxBase, d.Name()))
		if e != nil {
			if os.IsNotExist(e) {
				continue // removed between the two reads
			}
			return 0, e
		}
		for _, f := range ents {
			if m := pendName.FindStringSubmatch(f.Name()); m != nil {
				pending[pendKey{m[3], m[4]}] = true
				n++
			} else if sealedName.MatchString(f.Name()) {
				n++
			}
		}
	}
	owner, err := os.ReadDir(ownerInboxBase)
	if err != nil && !os.IsNotExist(err) {
		return 0, err
	}
	for _, f := range owner {
		if !f.IsDir() && ownerItemName.MatchString(f.Name()) {
			n++
		}
	}
	boxes, err := os.ReadDir(telIngestBase)
	if err != nil && !os.IsNotExist(err) {
		return 0, err
	}
	for _, f := range boxes {
		m := mailboxName.FindStringSubmatch(f.Name())
		if m == nil || !f.Type().IsRegular() || (m[2] != "" && !isSimTag(m[2])) {
			continue
		}
		b, e := os.ReadFile(filepath.Join(telIngestBase, f.Name()))
		if e != nil {
			if os.IsNotExist(e) {
				continue // consumed between the two reads
			}
			return 0, e
		}
		n += countUnpairedRows(string(b), func(key string) bool { return pending[pendKey{m[1], rowKeyHash(m[1], key)}] })
	}
	return n, nil
}

// countUnpairedRows counts the newline-terminated rows of a mailbox file that paired reports no pending copy for. It
// is given the row key (the first two fields) and keeps nothing of the row.
func countUnpairedRows(data string, paired func(key string) bool) int {
	rows := 0
	for len(data) > 0 {
		i := strings.IndexByte(data, '\n')
		if i < 0 {
			break // a trailing segment with no newline is not a row
		}
		line := data[:i]
		data = data[i+1:]
		if f := strings.Fields(line); len(f) >= 2 && paired(f[0]+" "+f[1]) {
			continue
		}
		rows++
	}
	return rows
}

// pendingTelWords renders the count for a log line: a number, or "an unknown number of" when it could not be read.
func pendingTelWords() (words string, pending bool) {
	n, err := telPendingCount()
	if err != nil {
		return "an unknown number of", true
	}
	return strconv.Itoa(n), n > 0
}
