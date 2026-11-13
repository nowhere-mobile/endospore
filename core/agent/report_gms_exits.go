package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// NWP-20261201-02: why this session's Play services processes exited, from the framework's own record
// (ApplicationExitInfo), for an in-session issue report. Evidence for the backlog row "Play services' push process
// can be frozen for the rest of a session"; a start time says that a process restarted, this says why. No rule, no
// notice, no fix.
//
// PRIVACY: session scope only; only the two fixed gms process names; only this session's user; only records younger
// than this session, so a reused user id never shows a departed session's record. The description, trace, memory and
// state fields are never read. The login daemon cannot run dumpsys, so roamd's `gmsexits` op (read-only lane) pipes
// the dump into `nowhere_agent gmsexits <uid>`, which keeps the words and the digits below and nothing else.

// gmsExitsMaxRecords caps the records in the reply and in the report's keys.
const gmsExitsMaxRecords = 8

// gmsExitsClockLayout has no zone on purpose: the dump's stamps are the device's LOCAL time and the static agent has
// no zoneinfo, so both ends of an age are parsed as the same naive clock.
const gmsExitsClockLayout = "2006-01-02 15:04:05"

// The fixed shape of ApplicationExitInfo.dump (AOSP frameworks/base). The header pattern is wide on purpose: a changed
// header must still open a block, so that the block fails on its field lines and the reply is an honest ERR-DUMP. A
// narrow header would leave blocks at 0 and answer a false "OK 0 0".
var (
	gmsExitHeaderRe  = regexp.MustCompile(`^\s*ApplicationExitInfo\b`)
	gmsExitTimeRe    = regexp.MustCompile(`^\s*timestamp=(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d{3} pid=-?\d+ realUid=-?\d+ packageUid=-?\d+ definingUid=-?\d+ user=(\d+)\s*$`)
	gmsExitProcessRe = regexp.MustCompile(`^\s*process=(\S+) reason=-?\d+ \((.*)\) subreason=-?\d+ \((.*)\) status=\S+\s*$`)
	gmsExitImportRe  = regexp.MustCompile(`^\s*importance=(\d+) `)
	gmsExitNowRe     = regexp.MustCompile(`^nowhere-now=\d+ (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)$`)
	gmsExitRcRe      = regexp.MustCompile(`^nowhere-dump-rc=(\d+)$`)
	gmsExitSepRe     = regexp.MustCompile(`[ ()]+`)
	gmsExitWordRe    = regexp.MustCompile(`^[A-Z_]{1,40}$`)
	gmsExitLineRe    = regexp.MustCompile(`^(?:persistent|main) reason=(?:[A-Z_]{1,40}|unparsed) sub=(?:[A-Z_]{1,40}|unparsed) imp=\d{1,9} age_s=(\d{1,12})$`)
	gmsExitOKRe      = regexp.MustCompile(`^OK (\d{1,9}) \d{1,9}$`)
)

// gmsExitLabels holds the only two processes a report may name.
var gmsExitLabels = map[string]string{
	"com.google.android.gms.persistent": "persistent",
	"com.google.android.gms":            "main",
}

// normalizeGmsWord maps a framework word to the report's alphabet. The framework's words carry spaces and parentheses
// (APP CRASH(EXCEPTION), OTHER KILLS BY SYSTEM), so a run of those becomes one underscore; anything else outside the
// alphabet makes the word `unparsed`, with no input text.
func normalizeGmsWord(s string) string {
	w := strings.Trim(gmsExitSepRe.ReplaceAllString(s, "_"), "_")
	if !gmsExitWordRe.MatchString(w) {
		return "unparsed"
	}
	return w
}

// parseGmsExits turns roamd's stdin (the nowhere-now line, the dump, the nowhere-dump-rc line) into the reply:
// `OK <kept> <dropped>` and one line per kept record, newest first, or `ERR-DUMP <why>` with fixed text. An empty
// dump is a failed read, never "no exits": a denied dumpsys prints nothing and exits 0, so the framework's header is
// required. A dump whose every block failed to parse is a failed read too (the always-honest rule of
// uiderrorsSection): `dropped` reaches no report key, so it must not carry the only sign of a format change.
func parseGmsExits(dump, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return "ERR-DUMP bad user id"
	}
	lines := strings.Split(strings.ReplaceAll(dump, "\r\n", "\n"), "\n")
	nowMatch := gmsExitNowRe.FindStringSubmatch(lines[0])
	if nowMatch == nil {
		return "ERR-DUMP no clock line"
	}
	now, err := time.Parse(gmsExitsClockLayout, nowMatch[1])
	if err != nil {
		return "ERR-DUMP no clock line"
	}
	last := len(lines) - 1
	for last > 0 && strings.TrimSpace(lines[last]) == "" {
		last--
	}
	rc := gmsExitRcRe.FindStringSubmatch(lines[last])
	if rc == nil {
		return "ERR-DUMP no exit status line"
	}
	if rc[1] != "0" {
		return "ERR-DUMP dumpsys exited non-zero"
	}
	sawHeader := false
	for _, ln := range lines[1:last] {
		if strings.HasPrefix(strings.TrimSpace(ln), "ACTIVITY MANAGER PROCESS EXIT INFO") {
			sawHeader = true
			break
		}
	}
	if !sawHeader {
		return "ERR-DUMP no framework header"
	}

	type gmsExitRecord struct {
		age  int64
		line string
	}
	type gmsExitBlock struct {
		stamp, user, process, reason, sub, imp string
	}
	var kept []gmsExitRecord
	var cur *gmsExitBlock
	blocks, parsed, dropped := 0, 0, 0
	flush := func() {
		if cur == nil {
			return
		}
		b := cur
		cur = nil
		var ts time.Time
		complete := b.stamp != "" && b.process != "" && b.imp != ""
		if complete {
			var perr error
			ts, perr = time.Parse(gmsExitsClockLayout, b.stamp)
			complete = perr == nil
		}
		if !complete {
			dropped++
			return
		}
		parsed++
		if b.user != uid {
			dropped++
			return
		}
		label, ok := gmsExitLabels[b.process]
		if !ok {
			dropped++
			return
		}
		age := int64(now.Sub(ts) / time.Second)
		if age < 0 { // a clock step: a negative age cannot prove that the record is younger than the session
			dropped++
			return
		}
		kept = append(kept, gmsExitRecord{age, fmt.Sprintf("%s reason=%s sub=%s imp=%s age_s=%d",
			label, normalizeGmsWord(b.reason), normalizeGmsWord(b.sub), b.imp, age)})
	}
	for _, ln := range lines[1:last] {
		if gmsExitHeaderRe.MatchString(ln) {
			flush()
			cur = &gmsExitBlock{}
			blocks++
			continue
		}
		if cur == nil {
			continue
		}
		if m := gmsExitTimeRe.FindStringSubmatch(ln); m != nil && cur.stamp == "" {
			cur.stamp, cur.user = m[1], m[2]
		} else if m := gmsExitProcessRe.FindStringSubmatch(ln); m != nil && cur.process == "" {
			cur.process, cur.reason, cur.sub = m[1], m[2], m[3]
		} else if m := gmsExitImportRe.FindStringSubmatch(ln); m != nil && cur.imp == "" {
			cur.imp = m[1]
		}
	}
	flush()
	if blocks > 0 && parsed == 0 {
		return "ERR-DUMP no exit-info block parsed"
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].age < kept[j].age })
	if len(kept) > gmsExitsMaxRecords {
		dropped += len(kept) - gmsExitsMaxRecords
		kept = kept[:gmsExitsMaxRecords]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "OK %d %d\n", len(kept), dropped)
	for _, r := range kept {
		b.WriteString(r.line + "\n")
	}
	return b.String()
}

// gmsExitsWait bounds how long a report waits for the worker: a wedged worker costs one honest key, never the report.
var gmsExitsWait = 15 * time.Second

// gmsExitsWorker is the read-only-lane request; a var so that a test can stand in for the lane. Never a passphrase.
var gmsExitsWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "gmsexits", name, "", uid, "", nil)
}

// fetchGmsExits asks the worker for this session's records. The op runs on in its goroutine if the wait expires; it
// only reads, and the lane's own slot keeps it from piling up.
func fetchGmsExits(dest, name, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return ""
	}
	ch := make(chan string, 1)
	goSafe("gmsexits", func() { ch <- gmsExitsWorker(dest, name, uid) })
	select {
	case r := <-ch:
		return r
	case <-time.After(gmsExitsWait):
		return fmt.Sprintf("ERR-TIMEOUT the worker did not answer within %s", gmsExitsWait)
	}
}

// gmsExitsNotCollected names why a non-OK reply carries no record, in the key's fixed words; no reply text is carried.
func gmsExitsNotCollected(reply string) string {
	switch {
	case reply == "":
		return "not-collected-empty"
	case strings.HasPrefix(reply, "ERR-LANE"), strings.HasPrefix(reply, workerBusy):
		return "not-collected-lane"
	case strings.HasPrefix(reply, "ERR-TIMEOUT"):
		return "not-collected-timeout"
	case strings.HasPrefix(reply, "ERR-DUMP"), strings.HasPrefix(reply, "ERR-READ"):
		return "not-collected-dump"
	}
	return "not-collected-malformed"
}

// mergeGmsExits adds the records to an in-session report's status, after buildIssueReportWith (so outside its size
// trim: about 700 bytes at most). It first deletes every caller-sent gms_exit* key, at both scopes, so only this file
// can set one; the keys skip statusValue because the fixed shape checked here is stricter than that scrub.
//
// The session's age comes from the mtime of .roamsession and is read BEFORE the fetch: the dump is then the later
// clock, so a record older than the session always has age_s >= the session's age and is dropped. A rewrite of the
// marker during a session (a passphrase change, for one) only withholds more, the safe direction.
func mergeGmsExits(status map[string]string, fetch func() string, dest string, deviceScope bool) {
	for k := range status {
		if strings.HasPrefix(k, "gms_exit") {
			delete(status, k)
		}
	}
	if deviceScope || status == nil {
		return
	}
	st, err := os.Stat(filepath.Join(dest, roamSessionFile))
	if err != nil {
		status["gms_exits"] = "unread-session-start"
		return
	}
	sessionAge := int64(time.Since(st.ModTime()) / time.Second)
	reply := strings.TrimRight(strings.ReplaceAll(fetch(), "\r\n", "\n"), "\n")
	first, rest, _ := strings.Cut(reply, "\n")
	if !strings.HasPrefix(first, "OK") {
		status["gms_exits"] = gmsExitsNotCollected(strings.TrimSpace(first))
		return
	}
	head := gmsExitOKRe.FindStringSubmatch(first)
	var lines []string
	if rest != "" {
		lines = strings.Split(rest, "\n")
	}
	if head == nil || head[1] != strconv.Itoa(len(lines)) || len(lines) > gmsExitsMaxRecords {
		status["gms_exits"] = "not-collected-malformed"
		return
	}
	n := 0
	for _, ln := range lines {
		value := "unparsed" // a line of another shape carries no input text
		if m := gmsExitLineRe.FindStringSubmatch(ln); m != nil {
			age, perr := strconv.ParseInt(m[1], 10, 64)
			if perr != nil || age >= sessionAge {
				continue // an earlier session with the same user id
			}
			value = ln
		}
		n++
		status["gms_exit_"+strconv.Itoa(n)] = value
	}
	status["gms_exits"] = strconv.Itoa(n)
}
