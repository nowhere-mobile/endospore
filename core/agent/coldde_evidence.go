package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"regexp"
)

// coldDeUnparkFile is roamd's summary, in the state tmpfs, of the accounts_de.db that the last cold-lock resume found
// re-created while the real file was parked (nowhere_roamd.sh, de_unpark and the deunpark op).
const coldDeUnparkFile = "coldde-unpark"

// coldDeUnparkMaxBytes bounds what a report reads of the file. Defence only: no valid line exceeds about 180 bytes.
const coldDeUnparkMaxBytes = 256

// coldDeUnparkRe is the file's only accepted shape: one line, the nine fields in this order, digits or `na` only.
var coldDeUnparkRe = regexp.MustCompile(`^v=1 found=([01]) after_park_s=([0-9]{1,12}|na) db_bytes=([0-9]{1,12}|na) wal_bytes=([0-9]{1,12}|na) emails=([0-9]{1,12}|na) ss_fds=([0-9]{1,12}|na) pkgs_delta_s=(-?[0-9]{1,12}|na) pkgr_delta_s=(-?[0-9]{1,12}|na)\n?$`)

// coldDeUnparkStatus renders the last cold-lock resume's re-created accounts_de.db figures as issue-report status keys
// (NWP-20261206-23, backlog: During a cold lock, AccountManagerService's own handler thread re-creates an EMPTY
// `accounts_de.db` for the stopped user). Session scope only: whether and when this session's account file came back
// is a profile fact.
//
//	coldde_found         "0"|"1" a re-created accounts_de.db sat in the parked file's place at the resume
//	coldde_after_park_s  "<n>"|"na" seconds from the park to that file's creation
//	coldde_db_bytes      "<n>"|"na" the re-created file's size
//	coldde_wal_bytes     "<n>"|"na" its WAL's size
//	coldde_emails        "<n>"|"na" email-shaped strings in the file and its WAL (0 = metadata only)
//	coldde_ss_fds        "<n>"|"na" system_server fds open on it
//	coldde_pkgs_delta_s  "<n>"|"na" seconds between the creation and the user's last package-state write (signed)
//	coldde_pkgr_delta_s  "<n>"|"na" seconds between the creation and its last package-restrictions write (signed)
//
// The writer (de_unpark) defines both deltas; this reader only checks their shape.
//
// The row names two candidate callers. A small pkgs or pkgr delta points at the package monitor
// (onPackageAdded/Removed); large ones point at the timed account-notification work.
//
// A missing file gives no keys (no cold-lock resume found one this session, or the writer is not on the image). Any
// other read error, an oversized file or any other shape gives coldde_evidence=unreadable alone. It never copies any
// other text.
func coldDeUnparkStatus(path string) map[string]string {
	unreadable := map[string]string{"coldde_evidence": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, coldDeUnparkMaxBytes+1))
	if err != nil || len(b) > coldDeUnparkMaxBytes {
		return unreadable
	}
	m := coldDeUnparkRe.FindSubmatch(b)
	if m == nil {
		return unreadable
	}
	return map[string]string{
		"coldde_found":        string(m[1]),
		"coldde_after_park_s": string(m[2]),
		"coldde_db_bytes":     string(m[3]),
		"coldde_wal_bytes":    string(m[4]),
		"coldde_emails":       string(m[5]),
		"coldde_ss_fds":       string(m[6]),
		"coldde_pkgs_delta_s": string(m[7]),
		"coldde_pkgr_delta_s": string(m[8]),
	}
}
