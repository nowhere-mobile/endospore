package main

// NWP-20261117-38: the OTA-REFRESH branch's `[ota] OTA-REFRESH forced` line, limited per caller. Backlog row
// "`[ota] OTA-REFRESH forced` lines crowd the issue report's login.log tail: every gate appearance and every OTA wake
// alarm forces a refresh that logs one". The gate sends the verb at every appearance (ChooserActivity.checkForOta from
// onResume) and the OTA wake receiver every 2 h and at each power connection, and each call logged one line. lynx
// 2026102901: login.log held 284 of them, 115 of its last 400 lines, and an issue report's login.log tail (the last
// maxIssueLogLines) was dominated by them, which pushed out the sign-in and sign-out lines it was filed for.
//
// Only the log line is limited. kickOtaRefresh and the CHECKING / DONE / NOSTORE replies run on every call as before.

import (
	"fmt"
	"io"
	"sync"
	"time"
)

// otaRefreshLogEvery is the window: at most one line per caller tag per hour. An hour keeps a whole day to at most
// 24 lines per caller, which cannot crowd a 300-line report tail, and still shows every hour that the caller is alive.
// A folded call is counted, not dropped: the next line of that caller says how many calls it stands for.
const otaRefreshLogEvery = time.Hour

type otaRefreshLogger struct {
	mu     sync.Mutex
	now    func() time.Time     // the clock; tests pass a fake one
	last   map[string]time.Time // tag class -> wall time of its last printed line
	folded map[string]int       // tag class -> calls folded since that line
}

func newOtaRefreshLogger(now func() time.Time) *otaRefreshLogger {
	return &otaRefreshLogger{now: now, last: map[string]time.Time{}, folded: map[string]int{}}
}

// otaRefreshLog is the daemon's one limiter. Its own mutex is a leaf lock: line takes no other lock.
var otaRefreshLog = newOtaRefreshLogger(time.Now)

// otaRefreshTag maps the caller's raw second line to the closed set of tags the chooser sends. Anything else is
// "other": the raw value comes from a socket peer and is never echoed into the log.
func otaRefreshTag(raw string) string {
	switch raw {
	case "gate", "alarm", "power", "tap":
		return raw
	}
	return "other"
}

// line returns the line to print (with its newline) and true, or "" and false when the call is folded.
func (l *otaRefreshLogger) line(raw string) (string, bool) {
	// WALL clock (NWP-20260824-03, the rule above otaCacheTTL): the monotonic reading stops while the phone sleeps,
	// and the OTA wake alarm fires every 2 h of REAL time through sleep. On the monotonic clock an idle phone would
	// fold the alarm lines for days, and the next line would report a burst that never happened. DO NOT tidy the
	// Round(0) away.
	now := l.now().Round(0)
	tag := otaRefreshTag(raw)
	if tag == "tap" {
		// A person's Check for updates: always logged, never folded, and it leaves the other tags' windows alone.
		return "[ota] OTA-REFRESH forced (caller=tap)\n", true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	last, seen := l.last[tag]
	if seen && !now.Before(last) && now.Sub(last) < otaRefreshLogEvery {
		l.folded[tag]++
		return "", false
	}
	s := fmt.Sprintf("[ota] OTA-REFRESH forced (caller=%s)", tag)
	if n := l.folded[tag]; n > 0 {
		s += fmt.Sprintf(" (+%d folded since %s)", n, now.Sub(last).Round(time.Second))
	}
	l.last[tag], l.folded[tag] = now, 0
	return s + "\n", true
}

// note writes line's output, when there is one, to w.
func (l *otaRefreshLogger) note(w io.Writer, raw string) {
	if s, ok := l.line(raw); ok {
		fmt.Fprint(w, s)
	}
}
