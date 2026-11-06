package main

// NWP-20261124-12: A BETA SESSION'S DAY SUMMARY AS ONE ISSUE-REPORT STATUS KEY (slice 1 of two).
//
// The backlog row "A beta profile has no way to send a diagnostic report on a schedule ..." and the decision of
// 2026-11-02 in docs/product-decisions.md ("on the beta stack only, a profile can opt in to a diagnostic report every
// 6 hours with an all-day summary"): a report's logs are each log's last 299 lines, so a report sent after a bad
// afternoon holds only the last hour, and the sign-in and saves that went wrong earlier are gone. Nothing kept a
// session-long record. This file keeps one, numbers only, while the session has opted in.
//
// "Beta" is the device's STORE being the beta stack (the decision's "Beta only" inference), not the build type or
// the OTA ring: every Endospore release image is built with the beta-setup ring, whose conf sets only
// NOWHERE_GATEWAY_DEFAULT. So daySummaryOffered reads GATEWAY_URL alone -- the value a managed enrolment writes --
// and never NOWHERE_GATEWAY_DEFAULT or issueGatewayURL's fallback to it.
//
// The opt-in marker is $STATE/day-summary-on.<uid>; the summary is $STATE/day-summary.<uid> (the state tmpfs),
// written only while the marker exists. Its only line shapes, one per event:
//
//	v=1 t=<unix s> ev=signin ms=<vault>+<de>+<media>+<apps>+<sys>                     DIAG-SUMMARY on, from signin-summary.<uid>
//	v=1 t=<unix s> ev=save ms=<n> rc=<ok|partial|refused|timeout|busy|err> kib=<n|->   triggerRoamWorkerKind, periodic + manual
//	v=1 t=<unix s> ev=sweep apps=<n> ok=<n> fail=<n> ms=<n>                            DIAG-EVENT sweep (the chooser's Auto sweep)
//
// A save line's kib (NWP-20261128-29) is that run's upload KiB, the sum of <dest>/seal-split (push_stat.go), or "-"
// when the run left none. A save line without kib (written before NWP-20261128-29) still reads.
//
// Each append drops lines older than 24 h, then the oldest lines until the file is at most 16 KiB. An in-session
// report reads its own uid's file whole into one key:
//
//	day_summary   the file's lines joined by ';', or "unreadable" when the file is over 16 KiB or ANY line is of
//	              another shape
//
// A missing or empty file gives no key. It never copies any other text: no profile name, no path, no package.
// Diagnostics only: nothing about what is saved, restored, or when, changes, and every error is ignored.

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// daySummaryPrefix and daySummaryOnPrefix name the summary and the opt-in marker in the state tmpfs.
const daySummaryPrefix = "day-summary."
const daySummaryOnPrefix = "day-summary-on."

// daySummaryMaxBytes bounds the file: the writer keeps it at most this long, and a longer file reads as unreadable.
const daySummaryMaxBytes = 16 << 10

// daySummaryMaxAge is how far back the summary reaches.
const daySummaryMaxAge = 24 * time.Hour

// daySummaryBetaHost is the beta stack's gateway host, the ONE place it is named here. A test pins it to
// rings/beta.conf's GATEWAY_URL and rings/beta-setup.conf's NOWHERE_GATEWAY_DEFAULT.
const daySummaryBetaHost = "api-beta.nowhere.mobile"

// daySummaryNow is the clock; tests replace it.
var daySummaryNow = time.Now

// daySummaryMu serialises every write, opt-in, opt-out and forget of the two files.
var daySummaryMu sync.Mutex

// The file's only accepted line shapes, and DIAG-EVENT's only accepted argument.
var daySummarySigninRe = regexp.MustCompile(`^v=1 t=([0-9]{1,12}) ev=signin ms=([0-9]{1,12}|-)\+([0-9]{1,12}|-)\+([0-9]{1,12}|-)\+([0-9]{1,12}|-)\+([0-9]{1,12}|-)$`)
var daySummarySaveRe = regexp.MustCompile(`^v=1 t=([0-9]{1,12}) ev=save ms=([0-9]{1,12}) rc=(ok|partial|refused|timeout|busy|err)( kib=([0-9]{1,15}|-))?$`)
var daySummarySweepRe = regexp.MustCompile(`^v=1 t=([0-9]{1,12}) ev=sweep apps=([0-9]{1,12}) ok=([0-9]{1,12}) fail=([0-9]{1,12}) ms=([0-9]{1,12})$`)
var daySummaryEventRe = regexp.MustCompile(`^sweep ([0-9]{1,12}) ([0-9]{1,12}) ([0-9]{1,12}) ([0-9]{1,12})$`)

// daySummaryLineT returns a line's t when the line has one of the three shapes.
func daySummaryLineT(l string) (int64, bool) {
	for _, re := range []*regexp.Regexp{daySummarySigninRe, daySummarySaveRe, daySummarySweepRe} {
		if m := re.FindStringSubmatch(l); m != nil {
			t, err := strconv.ParseInt(m[1], 10, 64)
			return t, err == nil
		}
	}
	return 0, false
}

// daySummaryUIDOK is mergeSigninSummary's uid check: non-empty, digits only.
func daySummaryUIDOK(uid string) bool { return uid != "" && strings.Trim(uid, "0123456789") == "" }

func daySummaryPath(uid string) string { return filepath.Join(loginStateDir(), daySummaryPrefix+uid) }

func daySummaryMarker(uid string) string {
	return filepath.Join(loginStateDir(), daySummaryOnPrefix+uid)
}

// daySummaryOffered: the phone is ENROLLED on the beta stack -- GATEWAY_URL's host is exactly the beta host.
func daySummaryOffered() bool {
	u, err := url.Parse(strings.TrimSpace(os.Getenv("GATEWAY_URL")))
	return err == nil && u.Scheme == "https" && u.Host == daySummaryBetaHost
}

// daySummaryOn reports whether the session (uid) has opted in.
func daySummaryOn(uid string) bool {
	if !daySummaryUIDOK(uid) {
		return false
	}
	_, err := os.Stat(daySummaryMarker(uid))
	return err == nil
}

// daySummaryAppend appends one line to the uid's summary while its marker exists. Every error is ignored.
func daySummaryAppend(uid, line string) {
	if !daySummaryUIDOK(uid) {
		return
	}
	daySummaryMu.Lock()
	defer daySummaryMu.Unlock()
	daySummaryAppendLocked(uid, line)
}

// daySummaryAppendLocked is daySummaryAppend's body; the caller holds daySummaryMu. Read, drop the lines older than
// 24 h (and any line of another shape), append, drop the oldest until at most 16 KiB, then temp + rename.
func daySummaryAppendLocked(uid, line string) {
	if !daySummaryOn(uid) {
		return
	}
	path := daySummaryPath(uid)
	now := daySummaryNow().Unix()
	var keep []string
	if f, err := os.Open(path); err == nil {
		b, _ := io.ReadAll(io.LimitReader(f, daySummaryMaxBytes+1))
		_ = f.Close()
		for _, l := range strings.Split(string(b), "\n") {
			if t, ok := daySummaryLineT(l); ok && now-t <= int64(daySummaryMaxAge/time.Second) {
				keep = append(keep, l)
			}
		}
	}
	keep = append(keep, line)
	size := 0
	for _, l := range keep {
		size += len(l) + 1
	}
	for size > daySummaryMaxBytes && len(keep) > 1 {
		size -= len(keep[0]) + 1
		keep = keep[1:]
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(keep, "\n")+"\n"), 0o600); err != nil {
		_ = os.Remove(tmp)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
	}
}

// daySummarySigninLine is the signin line, built from the session's signin-summary.<uid> (`-` for a missing scope).
func daySummarySigninLine(uid string) string {
	s := signinSummaryStatus(filepath.Join(loginStateDir(), signinSummaryPrefix+uid))
	parts := make([]string, 0, 5)
	for _, scope := range []string{"vault", "de", "media", "apps", "sys"} {
		v := s["signin_"+scope+"_ms"]
		if v == "" || strings.Trim(v, "0123456789") != "" {
			v = "-"
		}
		parts = append(parts, v)
	}
	return fmt.Sprintf("v=1 t=%d ev=signin ms=%s", daySummaryNow().Unix(), strings.Join(parts, "+"))
}

// daySummarySaveRC is the CLOSED map from a save's worker reply to the save line's rc word.
func daySummarySaveRC(out string) string {
	switch v := sealVerb(out); {
	case (v == "OK" || strings.HasPrefix(v, "OK ")) && strings.Contains(out, " PARTIAL:"):
		return "partial"
	case v == "OK" || strings.HasPrefix(v, "OK "):
		return "ok"
	case v == "ERR-REFUSED":
		return "refused"
	case v == "ERR-TIMEOUT":
		return "timeout"
	case v == workerBusy:
		return "busy"
	}
	return "err"
}

// daySummarySaveKiB is the save line's kib: the sum of this run's seal split (push_stat.go), or "-". The split is
// this run's only when out is a verdict roamd's out arm wrote (sealSplitVerdicts) and the file is not older than
// the op's start (t0): a run whose out arm wrote nothing must not read an older run's file. It never removes the
// file (syncLoop's takeSealSplit does).
func daySummarySaveKiB(dest string, t0 time.Time, out string) string {
	if !sealSplitVerdicts[sealVerb(out)] {
		return "-"
	}
	st, err := os.Stat(filepath.Join(dest, sealSplitFile))
	if err != nil || st.ModTime().Before(t0) {
		return "-"
	}
	kib, ok := sealSplitKiB(readSealSplit(dest))
	if !ok {
		return "-"
	}
	return strconv.FormatInt(kib, 10)
}

// daySummaryRecordSave is triggerRoamWorkerKind's deferred writer: one save line for every return of a periodic or
// manual (Back up now) `out`, with the op's WALL ms (t0 is time.Now().Round(0), NWP-20260913-18), its reply's rc and
// this run's upload KiB (daySummarySaveKiB). The marker check is in the append, so a session that has not opted in
// writes nothing.
func daySummaryRecordSave(op, intent, uid, dest string, t0 time.Time, out *string) {
	if op != "out" || (intent != "periodic" && intent != "manual") || out == nil {
		return
	}
	daySummaryAppend(uid, fmt.Sprintf("v=1 t=%d ev=save ms=%d rc=%s kib=%s", daySummaryNow().Unix(),
		time.Since(t0).Milliseconds(), daySummarySaveRC(*out), daySummarySaveKiB(dest, t0, *out)))
}

// daySummaryForget removes the uid's marker and summary: the completed sign-out of that session (handleLogout).
func daySummaryForget(uid string) {
	if !daySummaryUIDOK(uid) {
		return
	}
	daySummaryMu.Lock()
	defer daySummaryMu.Unlock()
	path := daySummaryPath(uid)
	_ = os.Remove(daySummaryMarker(uid))
	_ = os.Remove(path)
	_ = os.Remove(path + ".tmp")
}

// daySummaryStatus renders a summary file as the day_summary key the file header describes.
func daySummaryStatus(path string) map[string]string {
	unreadable := map[string]string{"day_summary": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, daySummaryMaxBytes+1))
	if err != nil || len(b) > daySummaryMaxBytes {
		return unreadable
	}
	if len(b) == 0 {
		return map[string]string{}
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	for _, l := range lines {
		if _, ok := daySummaryLineT(l); !ok {
			return unreadable
		}
	}
	return map[string]string{"day_summary": strings.Join(lines, ";")}
}

// mergeDaySummary adds the session's own day summary (uid) to an in-session report's status, after
// buildIssueReportWith (so outside its size trim, as mergeSigninSummary). It deletes every caller-sent day_* key
// first, at every scope, so only this file can set one. Never read at device scope: a gate report carries none.
func mergeDaySummary(status map[string]string, uid string, deviceScope bool) {
	for k := range status { // a nil map ranges zero times
		if strings.HasPrefix(k, "day_") {
			delete(status, k)
		}
	}
	if deviceScope || status == nil || !daySummaryUIDOK(uid) {
		return
	}
	for k, v := range daySummaryStatus(daySummaryPath(uid)) {
		status[k] = v
	}
}

// daySummaryCaller is both verbs' caller check: the peer must be the live session's own Android user
// (peerUID / 100000 == the session's uid). User 0, root, system and every other user are refused with DENIED, before
// the request's argument is read; the log line names the verb only.
func daySummaryCaller(conn net.Conn, dest, verb string) (string, bool) {
	_, _, uid := readRoamSession(dest)
	peer := ownerPeerUID(conn)
	if daySummaryUIDOK(uid) && peer >= 0 && strconv.Itoa(peer/100000) == uid {
		return uid, true
	}
	fmt.Fprintf(os.Stderr, "[logind] %s: DENIED, not the live session's user (NWP-20261124-12)\n", verb)
	conn.Write([]byte("DENIED\n"))
	return "", false
}

// daySummaryArg reads the request's second line (the argument), as SIGNIN-SHOWN reads its code.
func daySummaryArg(r *bufio.Reader) (string, bool) {
	a, err := r.ReadString('\n')
	if err != nil && a == "" {
		return "", false
	}
	return strings.TrimRight(a, "\r\n"), true
}

// handleDiagSummary is DIAG-SUMMARY <on|off|status>, from the live session's own user only.
//
//	status -> OFFERED <0|1> ON <0|1>
//	on     -> ERR-NOT-BETA unless daySummaryOffered; else the marker, the signin line when no file exists yet, OK
//	off    -> the marker and the file removed, OK
func handleDiagSummary(conn net.Conn, r *bufio.Reader, dest string) {
	uid, ok := daySummaryCaller(conn, dest, "DIAG-SUMMARY")
	if !ok {
		return
	}
	arg, _ := daySummaryArg(r)
	b2i := func(b bool) int {
		if b {
			return 1
		}
		return 0
	}
	switch arg {
	case "status":
		fmt.Fprintf(conn, "OFFERED %d ON %d\n", b2i(daySummaryOffered()), b2i(daySummaryOn(uid)))
	case "on":
		if !daySummaryOffered() {
			conn.Write([]byte("ERR-NOT-BETA\n"))
			return
		}
		daySummaryMu.Lock()
		f, err := os.OpenFile(daySummaryMarker(uid), os.O_WRONLY|os.O_CREATE, 0o600)
		if err == nil {
			_ = f.Close()
			if _, serr := os.Stat(daySummaryPath(uid)); errors.Is(serr, fs.ErrNotExist) {
				daySummaryAppendLocked(uid, daySummarySigninLine(uid))
			}
		}
		daySummaryMu.Unlock()
		if err != nil {
			conn.Write([]byte("ERR-STATE\n"))
			return
		}
		conn.Write([]byte("OK\n"))
	case "off":
		daySummaryForget(uid)
		conn.Write([]byte("OK\n"))
	default:
		conn.Write([]byte("ERR-ARGS\n"))
	}
}

// handleDiagEvent is DIAG-EVENT sweep <apps> <ok> <fail> <ms>, from the live session's own user only, digits only.
// It appends one sweep line when the session has opted in (a no-op otherwise) and answers OK.
func handleDiagEvent(conn net.Conn, r *bufio.Reader, dest string) {
	uid, ok := daySummaryCaller(conn, dest, "DIAG-EVENT")
	if !ok {
		return
	}
	arg, _ := daySummaryArg(r)
	m := daySummaryEventRe.FindStringSubmatch(arg)
	if m == nil {
		conn.Write([]byte("ERR-ARGS\n"))
		return
	}
	daySummaryAppend(uid, fmt.Sprintf("v=1 t=%d ev=sweep apps=%s ok=%s fail=%s ms=%s", daySummaryNow().Unix(),
		m[1], m[2], m[3], m[4]))
	conn.Write([]byte("OK\n"))
}
