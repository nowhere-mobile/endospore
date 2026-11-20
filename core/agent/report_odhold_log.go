package main

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// NWP-20261206-15: the odhold_log section of an in-session issue report. It is the EVIDENCE for the backlog row
// "installd is denied `setattr` on the files of an on-demand app's parked data, which carry `system_data_file` inside
// a `.nowhere-odhold` directory labelled `app_data_file`". The row's next step is a device read: which installd call
// walks into the hold. The candidate from AOSP source is fixupAppData, which lchown()s every entry under a package dir
// whose gid is not the dir's, and hold_ondemand restores the parked files root:root. That is an INFERENCE, not a
// device read, so this code hard-codes no message: it counts whatever installd or libselinux says about the hold.
//
// What leaves the device: the tag (installd or SELinux), the priority letter, a message head with no digit and no dot
// (a package name holds a dot, so it never passes), a fixed hold class, a fixed errno text, a count and two times.
// Never a path, a user id, a package or a file name.

// odholdLogCmds is the one source, read through readDiagFn. An absolute path, as avcSourceCmds (NWP-20260908-12).
var odholdLogCmds = [][]string{{"/system/bin/logcat", "-d", "-b", "all", "-v", "threadtime", "-s", "installd:*", "SELinux:*"}}

var (
	// date, time, priority, tag, message; logcat pads the tag before " : ".
	odholdThreadtimeRe = regexp.MustCompile(`^(\d\d-\d\d) (\d\d:\d\d:\d\d)\.\d+\s+\d+\s+\d+\s+([VDIWEFA])\s+([^:]*?)\s*: (.*)$`)
	odholdUserRe       = regexp.MustCompile(`(?:/data/user/|/data/user_de/|/data/media/|/emulated/)(\d+)/`)
	odholdHeadRe       = regexp.MustCompile(`^[A-Za-z][A-Za-z ':-]{0,59}$`)
	odholdHoldRes      = []struct {
		class string
		re    *regexp.Regexp
	}{
		{"ce", regexp.MustCompile(`/data/user/\d+/com\.nowhere\.chooser/\.nowhere-odhold/`)},
		{"de", regexp.MustCompile(`/data/user_de/\d+/com\.nowhere\.chooser/\.nowhere-odhold/`)},
		{"ext-data", regexp.MustCompile(`/Android/data/com\.nowhere\.chooser/\.nowhere-odhold/`)},
		{"ext-obb", regexp.MustCompile(`/Android/obb/com\.nowhere\.chooser/\.nowhere-odhold/`)},
	}
)

// odholdErrnoTexts is the closed set of strerror texts an errno class may carry. Free text never passes: a file name
// may follow a ": ".
var odholdErrnoTexts = map[string]bool{
	"Permission denied":                 true,
	"Operation not permitted":           true,
	"No such file or directory":         true,
	"Read-only file system":             true,
	"Not a directory":                   true,
	"Is a directory":                    true,
	"Directory not empty":               true,
	"File exists":                       true,
	"No space left on device":           true,
	"Too many levels of symbolic links": true,
	"Invalid argument":                  true,
	"Device or resource busy":           true,
}

const odholdLogMaxGroups = 40

// odholdLogLines groups the installd and SELinux lines of a `logcat -v threadtime` dump that name this session's
// on-demand hold. Pure. An empty uid keeps nothing.
//
// The rendered line puts the head and the errno in square brackets, not double quotes: scrubIssueLines rewrites every
// double-quoted token to "<name>" (reIssueQuotedTok, DIA-20260807-14), which would delete the one fact this section
// exists to carry.
func odholdLogLines(raw []byte, uid string) []string {
	if uid == "" {
		return nil
	}
	type group struct {
		n           int
		first, last string
	}
	groups := map[string]*group{}
	for _, ln := range strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n") {
		m := odholdThreadtimeRe.FindStringSubmatch(ln)
		if m == nil {
			continue // a "--------- beginning of" banner, or not threadtime
		}
		when, level, tag, msg := m[1]+" "+m[2], m[3], m[4], m[5]
		if tag != "installd" && tag != "SELinux" {
			continue
		}
		if !strings.Contains(msg, "/.nowhere-odhold/") {
			continue
		}
		// logcat holds every session of this boot: keep only this session's user.
		u := odholdUserRe.FindStringSubmatch(msg)
		if u == nil || u[1] != uid {
			continue
		}
		head := msg
		if i := strings.Index(msg, "/"); i >= 0 {
			head = msg[:i]
		}
		head = strings.TrimSpace(head)
		if !odholdHeadRe.MatchString(head) {
			head = "other"
		}
		hold := "other"
		for _, h := range odholdHoldRes {
			if h.re.MatchString(msg) {
				hold = h.class
				break
			}
		}
		errno := ""
		if i := strings.LastIndex(msg, ": "); i >= 0 {
			errno = strings.TrimSpace(msg[i+2:])
			if !odholdErrnoTexts[errno] {
				errno = "other"
			}
		}
		key := fmt.Sprintf("odhold_log: %s %s [%s] hold=%s errno=[%s]", tag, level, head, hold, errno)
		g := groups[key]
		if g == nil {
			g = &group{first: when}
			groups[key] = g
		}
		g.n++
		g.last = when // logcat -d prints in time order
	}
	type row struct {
		n    int
		text string
	}
	var rows []row
	for k, g := range groups {
		rows = append(rows, row{g.n, fmt.Sprintf("%s n=%d first=%s last=%s", k, g.n, g.first, g.last)})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].n != rows[j].n {
			return rows[i].n > rows[j].n
		}
		return rows[i].text < rows[j].text
	})
	var out []string
	for _, r := range rows {
		out = append(out, r.text)
	}
	if len(out) > odholdLogMaxGroups {
		cut := len(out) - odholdLogMaxGroups
		out = append(out[:odholdLogMaxGroups], fmt.Sprintf("odhold_log: %d more group(s) cut", cut))
	}
	return out
}

// odholdLogSection renders the section so it always says which state it is in, as avcSection does: a source that
// could not be read is never shown as a clean hold.
func odholdLogSection(lines []string, srcs []diagSource, secrets []string) []string {
	var bad []string
	for _, s := range srcs {
		if !s.ok() {
			bad = append(bad, s.name+" ("+s.err+")")
		}
	}
	var head []string
	if len(srcs) > 0 && len(bad) == len(srcs) {
		head = append(head, "odhold_log: NO source could be read -- "+strings.Join(bad, "; ")+
			" -- this does NOT mean installd left the hold alone")
	}
	if len(lines) == 0 && len(bad) == 0 {
		head = append(head, "odhold_log: sources readable, no installd or SELinux line names this session's on-demand hold in the captured window")
	}
	return append(scrubIssueLines(head, secrets), scrubIssueLines(lines, secrets)...)
}

// mergeOdholdLog adds the odhold_log section at session scope only, for this session's uid only (as mergeHealth and
// mergeDaySummary). The gate never carries it: the hold exists only inside a session. Residual: a user id reused
// within one boot also counts the earlier session's lines; the section holds counts and fixed classes only.
func mergeOdholdLog(rep *issueReport, uid string, deviceScope bool, secrets ...string) {
	if rep == nil {
		return
	}
	if deviceScope {
		return
	}
	if rep.Logs == nil {
		rep.Logs = map[string][]string{}
	}
	if uid == "" {
		rep.Logs["odhold_log"] = []string{"odhold_log: this session's user id is unknown -- not collected"}
		return
	}
	raw, src := readDiagFn(odholdLogCmds[0][0], odholdLogCmds[0][1:]...)
	rep.Logs["odhold_log"] = odholdLogSection(odholdLogLines(raw, uid), []diagSource{src}, secrets)
}
