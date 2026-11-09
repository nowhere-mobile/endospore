package main

// gate.log -- the GATE's own device-scope diagnostic channel (NWP-20260914-02).
//
// WHY THIS EXISTS. On 2026-09-13 a tester reported the gate alarm flashing up and vanishing, and then not
// appearing at all, on a locked `user` build. Not one byte of evidence was obtainable, and that was
// structural rather than bad luck:
//
//   1. SET-GATE-ALARM wrote its file and replied OK with NO log line at all, so the relay could not be
//      confirmed or ruled out.
//   2. GateAlarmActivity logs only through android.util.Log, i.e. logcat, which a user build does not give
//      us -- every ticket's avc section says exactly that: "NO source could be read -- /system/bin/logcat
//      (permission denied)".
//   3. A GATE-filed report carries only {provision.log, ota.log}. The session logs are excluded DELIBERATELY
//      (see buildIssueReport), so the one log that does carry daemon lines is the one a gate report cannot
//      have.
//
// So the gate could not report on the gate. Three tickets were filed from it that night and all three were
// diagnostically empty. This file is the narrow, leak-free channel that fixes that.
//
// ⚠ THE SCOPE RULE IS NOT NEGOTIABLE, AND IT IS WHY THE GRAMMAR IS CLOSED. The gate report's preview renders
// ON SCREEN AT THE GATE, where the next person to pick the phone up can read it, and the report goes to a
// gateway that is supposed to learn nothing. So this file may carry facts about the DEVICE and the GATE and
// nothing whatever about a session: no profile name (not even a salted tag), no package name, no Android
// user id, no wall-clock or calendar value, no login verb or outcome, and no free-form string of any kind.
//
// The guarantee is STRUCTURAL, not a filter. gateLog takes a verb from a closed set and at most one key from
// a closed set. `ms` and `fields` carry an INTEGER; `in` carries one of four fixed bucket tokens that gateLog
// itself picks (gateInBucket). `d`, `m` and `s` (the gap since the previous line on each clock, and the
// suspend inside it) are buckets that gateLog itself picks too (gateGapBucket): no line carries an exact
// elapsed time. Exact gaps, summed from the boot's first line, placed every line on the boot's timeline, and
// with a report's uptime_s and created_at they gave the gate alarm's ring time back (h53 #7,
// docs/product-decisions.md, 2026-11-02). No caller-supplied string can reach the file, so there is nothing to
// scrub and no charset rule to get wrong -- a filter would have to be clever about a profile named "start",
// and this does not. A verb that is not in the set is written as `trace-unknown`: rejection is recorded, not
// silent, which is the lesson this feature has already paid for four times over.

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A var, not a const, so a test can point it at a temp file (the lastReboot* files do the same).
var gateLogPath = filepath.Join(issueLogDir(), "gate.log")

const (
	// FORTY, and the number is derived, not chosen: trimIssueReport halves the biggest section only when it
	// has MORE than 40 lines. A section capped at 40 can therefore never be halved -- it is carried whole or
	// dropped whole, and a reader never sees a gate trace whose beginning was silently removed. A
	// half-eaten alarm trace reads as "the alarm was never scheduled", which is worse than no trace at all.
	gateLogMaxLines = 40
	// Belt and braces on top of the line cap. With the closed grammar a line is ~40 bytes and cannot exceed
	// the per-line cap below, so this can only fire if something is very wrong -- in which case truncating
	// is still the right answer. 4 KiB against maxIssueReportBytes is noise: gate.log can never be the
	// reason ota.log is evicted.
	gateLogMaxBytes = 4 << 10
	gateLogMaxLine  = 128
)

// The closed verb set. Daemon-written verbs and chooser-originated ones (which arrive over GATE-TRACE) live
// in one table on purpose: one list cannot drift out of step with itself.
var gateLogVerbs = map[string]bool{
	// daemon (relay-clear-held, NWP-20261011-04: a clear held back while a sign-out runs)
	"start": true, "relay-set": true, "relay-set-src": true, "relay-clear": true, "relay-halfpair": true, "relay-clear-held": true,
	// NWP-20261028-05: a relay that stored nothing / a clear that failed, and a stored time whose owner file failed
	"relay-err": true, "relay-src-err": true,
	"silence-req": true, "silence-nosession": true, "silence-coldlock": true, "silence-notarget": true,
	"silence-ok": true, "silence-err": true, "silence-live": true,
	// NWP-20261028-12: a SILENCE-GATE-ALARM stash that names a user other than the session's (ERR-STALE)
	"silence-stale": true,
	// chooser, over GATE-TRACE
	"armed": true, "armed-inexact": true, "armed-err": true, "cancel-login": true, "cancel-dismiss": true,
	"consume": true, "consume-past": true, "fired": true, "fired-err": true,
	"ui-create": true, "ui-guard-self": true, "ui-guard-other": true, "ui-guard-err": true,
	"ui-ring": true, "ui-ring-err": true, "ui-vibrate-err": true,
	"ui-snooze": true, "ui-dismiss": true, "ui-destroy": true, "ui-destroy-long": true,
	"ui-silence-ok": true, "ui-silence-empty": true,
	// NWP-20261028-13: a non-OK SILENCE-GATE-ALARM reply (ERR-LIVE, NONE, ...) -- the clock may still ring
	"ui-silence-refused": true,
	// NWP-20261116-12: the gate alarm rang 10 minutes unattended and snoozed itself / was dismissed
	"ui-auto-snooze": true, "ui-auto-dismiss": true,
	// NWP-20261128-35: the gate window's two light-bar appearance bits at first focus, in light mode (0, 8, 16 or 24)
	"bars-light": true,
	// the record of a rejection -- never the rejected text itself
	"trace-unknown": true,
}

// The closed key set. Every value is a DURATION or a COUNT, never an instant:
//
//	in     how far off the relayed/armed trigger is, as ONE OF FOUR BUCKETS (gateInBucket): past, under1h,
//	       1to12h, over12h. Never the seconds themselves. An exact countdown plus a report's created_at and
//	       uptime_s rebuilds WHEN the alarm rings -- and an alarm that goes off at 06:30 on weekdays
//	       describes a person (#33, docs/product-decisions.md, 2026-10-22). The bucket still says whether
//	       the alarm was set, roughly how far out, and whether it was ALREADY PAST.
//	ms     milliseconds a UI surface lived, an INTEGER. A two-digit value IS the flash-and-vanish report.
//	fields how many tab-separated fields a wire line carried (0-3), an INTEGER. Shape, not content.
//	       For bars-light: the gate window's two light-bar bits (0, 8, 16 or 24), a property of the gate.
//
// `d`, `m` and `s` are not caller keys: gateLog writes them on every line, as gateGapBucket tokens.
var gateLogKeys = map[string]bool{"in": true, "ms": true, "fields": true}

var (
	gateLogMu sync.Mutex
	// The previous line's two clocks. d - m is SUSPEND, which is the thing the cold-lock work needed a
	// number for and could never get: CLOCK_BOOTTIME (bootUptime, sysinfo(2)) advances across suspend and
	// CLOCK_MONOTONIC does not.
	gateLogPrevUp   int64
	gateLogPrevMono time.Time
	gateLogPrimed   bool
)

// gateLogStart truncates the file and writes the first line. Called once, from the daemon's startup.
//
// ⚠ TRUNCATING AT EVERY BOOT IS A PRIVACY DECISION, NOT HOUSEKEEPING. It is what makes a cross-boot routine
// impossible to reconstruct rather than merely bounded, and it matches the design #151 already committed to:
// a power-off wipes the session AND its gate alarm, so the gate alarm's diary has no business outliving it.
// It also makes `d` unambiguous and makes 40 lines generous -- one boot's alarms, not a fortnight's.
func gateLogStart() {
	gateLogMu.Lock()
	gateLogPrimed = false
	gateLogMu.Unlock()
	if err := os.WriteFile(gateLogPath, nil, 0o600); err != nil {
		// Non-fatal and deliberately quiet about the path's contents: if the gate log cannot be written the
		// gate still works, and every caller below already degrades to doing nothing.
		fmt.Fprintf(os.Stderr, "[logind] gate.log: cannot truncate (%v)\n", err)
		return
	}
	gateLog("start", "", 0)
}

// gateLog appends one line: "d=<gap> m=<gap> s=<gap> <verb>[ in=<bucket>| <key>=<int>]".
//
// Each <gap> is gateGapBucket of a whole number of seconds since the previous line: d on the boot clock, m on
// the monotonic clock, and s the suspend between them (gateSuspendSeconds), never the seconds themselves.
//
// `in` is written as gateInBucket(val), never as val; `ms` and `fields` are written as the integer.
// Pass key "" to write no key. An unknown verb becomes `trace-unknown` and an unknown key is dropped -- the
// EVENT is still recorded, because a rejected trace that vanishes is the exact failure this file exists to
// end. Never blocks on anything but its own mutex, never returns an error, and never touches the caller's
// control flow: a diagnostic that can break the thing it observes is not worth having.
func gateLog(verb, key string, val int) {
	if !gateLogVerbs[verb] {
		verb = "trace-unknown"
	}
	if key != "" && !gateLogKeys[key] {
		key = ""
	}

	gateLogMu.Lock()
	defer gateLogMu.Unlock()

	up := gateUptimeSeconds()
	now := time.Now() // bare: monotonic ON PURPOSE here -- m must NOT advance across suspend
	var d, m int
	if gateLogPrimed {
		if up >= gateLogPrevUp {
			d = int(up - gateLogPrevUp)
		}
		if s := int(time.Since(gateLogPrevMono).Seconds()); s > 0 {
			m = s
		}
	}
	gateLogPrevUp, gateLogPrevMono, gateLogPrimed = up, now, true

	line := "d=" + gateGapBucket(d) + " m=" + gateGapBucket(m) + " s=" + gateGapBucket(gateSuspendSeconds(d, m)) + " " + verb
	if key == "in" {
		line += " " + key + "=" + gateInBucket(val)
	} else if key != "" {
		line += " " + key + "=" + strconv.Itoa(val)
	}
	if len(line) > gateLogMaxLine {
		line = line[:gateLogMaxLine]
	}
	gateLogAppendLocked(line)
}

// gateUptimeSeconds is bootUptime: CLOCK_BOOTTIME, which advances ACROSS suspend, ROUNDED UP to whole seconds
// by sysinfo(2). `d` was always an int; now both of its readings are rounded up, so for a true gap of t
// seconds d is floor(t) or floor(t)+1, while m is floor(t). ⚠ So with NO suspend at all d - m can read 1:
// d - m <= 1 is rounding, not suspend -- only a difference of 2 or more says the phone slept. Returns 0 when
// the clock cannot be read, which makes d read `none` rather than a fabricated number.
//
// ⚠ It read /proc/uptime until NWP-20261013-02, and the daemon's domain is denied proc_uptime on an
// enforcing build -- so on device it was ALWAYS that 0: d read 0 on every line, and d - m (the suspend the
// column exists to show) was never once a measurement.
func gateUptimeSeconds() int64 {
	up, err := bootUptime()
	if err != nil {
		return 0
	}
	return up
}

// gateLogAppendLocked appends and then enforces both caps by REWRITING IN PLACE.
//
// ⚠ Truncate in place, never rename. nowhere_roamd.sh's "Truncate-IN-PLACE (cat > file), never rename" note,
// above NOWHERE_LOGS, records why: a rename leaves any O_APPEND holder writing into an unlinked file forever,
// so the rotation silently stops the logging it was meant to bound.
func gateLogAppendLocked(line string) {
	f, err := os.OpenFile(gateLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line + "\n")
	_ = f.Close()

	b, err := os.ReadFile(gateLogPath)
	if err != nil {
		return
	}
	if len(b) <= gateLogMaxBytes {
		if n := strings.Count(string(b), "\n"); n <= gateLogMaxLines {
			return
		}
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) > gateLogMaxLines {
		lines = lines[len(lines)-gateLogMaxLines:]
	}
	out := strings.Join(lines, "\n") + "\n"
	for len(out) > gateLogMaxBytes && len(lines) > 1 {
		lines = lines[1:]
		out = strings.Join(lines, "\n") + "\n"
	}
	_ = os.WriteFile(gateLogPath, []byte(out), 0o600)
}

// gateInBucket is the `in` value gateLog writes: one of four fixed tokens, never the seconds (#33,
// docs/product-decisions.md, 2026-10-22, dn-1109 #4). sec < 0 is "past"; 0 <= sec < 3600 is "under1h";
// 3600 <= sec <= 43200 is "1to12h"; sec > 43200 is "over12h". The 12 h edge is inclusive (exactly 12 h is
// "1to12h"): the decision names the buckets, and this edge is the implementer's choice within it.
//
// ⚠ THIS IS THE PRIVACY CONTROL. The absolute time must never be written down: an alarm at 06:30 on
// weekdays and 09:00 at weekends describes a person's life, and the gate report is rendered on screen at the
// gate and shipped to a gateway that is supposed to learn nothing. An exact countdown is not safe either:
// with the report's created_at and uptime_s and the d= deltas, it gives the alarm's wall-clock time back.
// The bucket answers the questions we ask -- was it set, roughly how far out, was it ALREADY PAST (its own
// bug shape) -- and answers nothing else.
func gateInBucket(sec int) string {
	switch {
	case sec < 0:
		return "past"
	case sec < 3600:
		return "under1h"
	case sec <= 43200:
		return "1to12h"
	default:
		return "over12h"
	}
}

// gateGapBucket is the `d`, `m` and `s` value gateLog writes: one of six fixed tokens, never the seconds (h53
// #7, docs/product-decisions.md, 2026-11-02). sec <= 0 is "none"; 1-9 is "lt10s"; 10-59 is "lt1m"; 60-599 is
// "lt10m"; 600-3599 is "lt1h"; 3600 and up is "ge1h". ⚠ THE EDGES ARE THE DECISION'S DRAFTS, FOR CHESTER TO
// CORRECT. The zero bucket is the word "none", not the digit 0, so that no d=, m= or s= token is ever an
// integer and a check for an exact elapsed time can be a plain digits pattern.
//
// Why a bucket: the file is truncated at every boot, so exact gaps summed from the first line place each
// line on the boot's timeline, and a report's uptime_s and created_at turn that into the wall-clock time of
// the gate alarm's ring -- the routine #33 took out of `in=`. The bucket still says whether the lines were
// back to back, minutes apart or hours apart, and whether the phone slept between them.
func gateGapBucket(sec int) string {
	switch {
	case sec <= 0:
		return "none"
	case sec < 10:
		return "lt10s"
	case sec < 60:
		return "lt1m"
	case sec < 600:
		return "lt10m"
	case sec < 3600:
		return "lt1h"
	default:
		return "ge1h"
	}
}

// gateSuspendSeconds is the `s` gateLog buckets: d - m when that is 2 or more, else 0. d is rounded up and m
// down (see gateUptimeSeconds), so a difference of 1 is rounding, not a suspend.
func gateSuspendSeconds(d, m int) int {
	if s := d - m; s >= 2 {
		return s
	}
	return 0
}

// gateAlarmInSeconds turns SET-GATE-ALARM's absolute epoch-millis into SECONDS FROM NOW. Those seconds are
// only gateInBucket's input: gateLog writes the bucket, and the seconds are never written down.
//
// Unparseable input yields 0. No relay arm reaches this unparsed (each one runs only after the time parsed
// as a positive decimal), and a 0 is written as "under1h".
func gateAlarmInSeconds(epochMillis string) int {
	ms, err := strconv.ParseInt(strings.TrimSpace(epochMillis), 10, 64)
	if err != nil {
		return 0
	}
	return int((ms - time.Now().UnixMilli()) / 1000)
}

// gateTraceLine parses ONE GATE-TRACE payload: "<verb>[ <key>=<int>]".
//
// Split out so it can be tested without a socket. Returns the verb and key EXACTLY as gateLog will treat
// them, which is what lets a test assert the closed-set property rather than trusting it.
func gateTraceLine(s string) (verb, key string, val int) {
	fields := strings.Fields(strings.TrimSpace(s))
	if len(fields) == 0 {
		return "trace-unknown", "", 0
	}
	verb = fields[0]
	if len(fields) > 1 {
		if k, v, ok := strings.Cut(fields[1], "="); ok {
			if n, err := strconv.Atoi(v); err == nil {
				key, val = k, n
			}
		}
	}
	return verb, key, val
}
