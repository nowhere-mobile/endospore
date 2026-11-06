package main

import "strings"

// IDLE-TRACE (NWP-20260901-31) lets the user-0 chooser put one idle-machinery event into login.log, which the
// in-session issue reporter collects. The line is written unquoted, so log_scrub's quoted-token rule cannot take
// a profile name out of it. NWP-20261106-19: the first filter (120 bytes, [a-z0-9 =_-]) let ANY lowercase word
// through -- a profile named "alice" or "bob2" passed unchanged -- so the guarantee held only while every
// chooser caller sent fixed tokens. This is the closed vocabulary GATE-TRACE already keeps (gate_log.go), with
// the event's shape preserved because device proofs in docs/backlog.md quote these lines verbatim: a first token
// from a verb set, then words from a word set or key=integer under a closed key. Anything else is `?`, and an
// unknown verb makes the whole line `trace-unknown`: the rejection is logged, never the rejected text.
// TestIdleTraceVocabularyCoversTheChooser reads the chooser's sources, so a new trace token there fails a test
// here instead of being silently dropped.
// NWP-20261112-10: `permsrelay` is PermsLiveRecord's relay of a live session's permission changes to its capture.
// Its fields are user=<uid> and the word err only, never a package or profile name.
// NWP-20261116-14: pushdoze-roam gains tries=<n>, the number of login apply attempts (DozeApplyRetry).
// NWP-20261120-02: the idle cold lock's audio wait: `defer audio held=<n>`, `audio stopped`, `audio cap reached`.
// NWP-20261124-04: `abort committed`, the gate's trace when COLD-LOCK-ABORT answers COMMITTED (ColdLockAbortReply).

const idleTraceMaxBytes = 120

var idleTraceVerbs = map[string]bool{
	"screen": true, "arm": true, "cancel": true, "probe": true, "abort": true, "armreg": true, "defer": true,
	"fire": true, "installs": true, "pushdoze": true, "pushdoze-roam": true, "pushdoze-capture": true,
	"pushdoze-sweep": true, "pushdoze-relay": true, "permsrelay": true, "audio": true,
}

var idleTraceWords = map[string]bool{
	"on": true, "off": true, "userpresent": true, "split": true, "skip": true, "ok": true, "drop": true,
	"allusers": true, "user0-fallback": true, "veto": true, "nolock": true, "screenon": true, "latefire": true,
	"call": true, "cap": true, "reached": true, "err": true, "play": true, "tbird": true, "xmpp": true,
	"other": true, "installs": true, "audio": true, "stopped": true, "committed": true,
}

var idleTraceKeys = map[string]bool{
	"ms": true, "u": true, "explicit": true, "ctx": true, "secure": true, "probe": true, "match": true,
	"appid": true, "ok": true, "applied": true, "dropped": true, "live": true, "n": true, "user": true,
	"removed": true, "kept": true, "late": true, "screenon": true, "locked": true, "s": true, "held": true,
	"tries": true,
}

// idleTraceFilter is the charset rule: one line, cut to idleTraceMaxBytes, everything outside [a-z0-9 =_-] dropped.
func idleTraceFilter(ev string) string {
	ev = strings.TrimRight(ev, "\r\n")
	if len(ev) > idleTraceMaxBytes {
		ev = ev[:idleTraceMaxBytes]
	}
	var b strings.Builder
	for _, c := range ev {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' || c == '=' || c == '_' || c == '-' {
			b.WriteRune(c)
		}
	}
	return strings.TrimSpace(b.String())
}

// idleTraceInt reports whether v is -?[0-9]+.
func idleTraceInt(v string) bool {
	v = strings.TrimPrefix(v, "-")
	if v == "" {
		return false
	}
	for _, c := range v {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// idleTraceLine returns the text the IDLE-TRACE arm may print for ev: "" when nothing survives the charset
// filter, `trace-unknown` for an unknown verb, else the verb and each later token kept or replaced by `?`.
func idleTraceLine(ev string) string {
	toks := strings.Fields(idleTraceFilter(ev))
	if len(toks) == 0 {
		return ""
	}
	if !idleTraceVerbs[toks[0]] {
		return "trace-unknown"
	}
	for i, tok := range toks[1:] {
		if idleTraceWords[tok] {
			continue
		}
		if k, v, ok := strings.Cut(tok, "="); ok && idleTraceKeys[k] && idleTraceInt(v) {
			continue
		}
		toks[i+1] = "?"
	}
	return strings.Join(toks, " ")
}
