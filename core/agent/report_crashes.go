package main

import (
	"strconv"
	"strings"
)

// NWP-20261128-17 (Q121, docs/product-decisions.md 2026-10-20, "eighteen recommendations accepted"): an in-session
// issue report carries this session's app crashes. The chooser reads them from DropBox (CrashRecords: start-time and
// user filtered, newest five, 4096 chars each) and sends them newest first as "crashes", with the read's outcome as
// "crash_access" (ok, denied or error). That value IS the decision's check whether PEEK_DROPBOX_DATA works on each
// edition, so every in-session report carries it, from the first one filed.
//
// A gate report carries neither key nor the section, whatever the request holds: DropBox is device-wide, and Q121
// keeps every session's app list away from the gate. The agent decides the scope, not the caller, as for anr.
// The lines go oldest first, as in every other section, so the tail is the newest crash: the line cap here and
// trimIssueReport's halving both keep the newest. The section can be about 20 KiB, so the caller trims again.
const (
	maxIssueCrashes    = 5    // records taken from the request; the chooser sends at most this many
	maxIssueCrashBytes = 4096 // bytes kept of each record
	maxIssueCrashLines = 600  // lines kept of the merged section, the newest
)

// crashAccessValues is every crash_access value a report may carry. Any other value, "" included, is dropped, so a
// caller value is never copied into the report as free text.
var crashAccessValues = map[string]bool{"ok": true, "denied": true, "error": true}

// mergeCrashes adds crash_access, crash_n and the scrubbed "crashes" section to an in-session report. At device
// scope it does nothing. It writes no log line and starts no goroutine.
func mergeCrashes(rep *issueReport, access string, crashes []string, name string, deviceScope bool) {
	if rep == nil || deviceScope {
		return
	}
	if rep.Status == nil {
		rep.Status = map[string]string{}
	}
	if crashAccessValues[access] {
		rep.Status["crash_access"] = access
	}
	if len(crashes) > maxIssueCrashes {
		crashes = crashes[:maxIssueCrashes]
	}
	rep.Status["crash_n"] = strconv.Itoa(len(crashes))
	var lines []string
	for i := len(crashes) - 1; i >= 0; i-- { // the chooser sends newest first; the section is oldest first
		c := crashes[i]
		if len(c) > maxIssueCrashBytes {
			c = c[:maxIssueCrashBytes]
		}
		c = strings.ToValidUTF8(strings.ReplaceAll(c, "\r\n", "\n"), "")
		lines = append(lines, strings.Split(strings.TrimSuffix(c, "\n"), "\n")...)
	}
	lines = scrubIssueLines(lines, nameSpellings(name))
	if n := len(lines); n > maxIssueCrashLines {
		lines = lines[n-maxIssueCrashLines:]
	}
	if len(lines) == 0 {
		return
	}
	if rep.Logs == nil {
		rep.Logs = map[string][]string{}
	}
	rep.Logs["crashes"] = lines
}
