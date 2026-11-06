package main

// Device "Report an issue" (task ii, option c): the user taps a Profile row, sees exactly what will be sent,
// consents, and the daemon files a support report with the gateway (POST /support -> a quotable ticket).
//
// The whole product promise is amnesia + zero-knowledge, so a diagnostic bundle is a LOADED GUN: it must never
// carry a credential, a phone number, a map/message, or anything that re-identifies the user. This file is the
// scrub. It is deliberately paranoid -- aggressive redaction PLUS whole-line drops for credential keywords PLUS
// a hard size cap -- and the report is stored VERBATIM by the gateway (it transforms nothing), so the bytes the
// device decides to send here are the bytes that land. The chooser additionally shows the user the scrubbed
// preview before this ever runs. When in doubt the scrub over-redacts: a support engineer never needs a
// passphrase, a recovery phrase, a bearer token, a store ref, an exact phone number, or an SSID to triage.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// maxIssueLogLines caps each log's tail; maxIssueReportBytes is a device-side ceiling well under the gateway's
// 512 KiB so a report never bounces on size (413).
const (
	maxIssueLogLines = 300
	// maxIssueAvcLines caps the denial list. A policy gap usually shows as a handful of distinct denials
	// repeated many times; dedup means 120 distinct lines is generous, and it keeps the report well inside
	// the size ceiling so denials never push a real log out.
	maxIssueAvcLines = 120
	// DIA-20260811-10. prev_boot is the tail of the PREVIOUS boot's kernel log (pstore/ramoops) -- a panic or a
	// watchdog reset is in the last few lines, so 200 is generous for the part that carries the cause. anr keeps
	// only the HEADER lines of the newest traces (process, reason, timestamp); the full thread dumps run to
	// megabytes and would evict the logs under the byte ceiling, which would make the report worse, not better.
	maxIssuePrevBootLines = 200
	maxIssueAnrLines      = 60
	maxIssueReportBytes   = 200 << 10
	// NWP-20261010-06. uiderrors lines run ~150 B, so 120 is ~18 KiB: room for every destroy of one bad resume
	// (the stallion shape is a few dozen packages) without letting a years-old file crowd out the nowhere logs.
	// uiderrorsTailBytes bounds what the worker reads at all: the framework only ever appends to the file.
	maxIssueUiderrorsLines = 120
	uiderrorsTailBytes     = 64 << 10
)

// Whole-line DROP triggers: if a log line contains any of these (case-insensitive) it is removed entirely --
// these keywords flank credential/secret material and it is never worth the risk of a partial redaction miss.
// (The agent does not print passphrases today; this is defense-in-depth against a future log line that does.)
var issueDropKeywords = []string{
	"passphrase", "mnemonic", "recovery code", "recovery phrase", "seed phrase", "recovery ",
	// NWP-20260903-50: "recovery " carries a DELIBERATE TRAILING SPACE and it is load-bearing -- do not
	// "tidy" it to a bare "recovery". The shape that actually leaks is this codebase's OWN output format,
	// `RECOVERY <12 words>` (main.go create-vault / recover / the daemon replies), which none of the
	// longer keywords match. A BARE "recovery" would also swallow real diagnostics that merely mention it
	// in passing -- notably the corrupt-head-blob failure ("...that would overwrite the vault and drop
	// 2FA/recovery)") -- and this log is the ONLY diagnostic channel a user build has, so over-dropping
	// costs real debuggability. The trailing space catches the format and leaves the parenthetical forms.
	"secret_key", "s3_secret", "aws_secret", "private key", "-----begin",
	"authorization:", "bearer ", "x-amz-signature", "signature=", "password",
}

// Redaction patterns applied (in order) to every surviving line and to the user's note. RE2, compiled once.
var (
	reIssueKV       = regexp.MustCompile(`(?i)\b([a-z0-9_.\-]*(?:secret|token|key|pass|cred|sig|auth)[a-z0-9_.\-]*)(\s*[=:]\s*)\S+`) // sensitive KEY=VALUE -> keep key, drop value
	reIssueAWS      = regexp.MustCompile(`\b(?:AKIA|ASIA|AIDA|AROA|AGPA|ANPA)[A-Z0-9]{8,}\b`)                                        // AWS access-key IDs (too short for the b64 rule)
	reIssueURLQuery = regexp.MustCompile(`(https?://[^\s"']+?)\?[^\s"']*`)                                                           // presign/query -> host+path only
	reIssueRefTok   = regexp.MustCompile(`(?i)\b(?:ref|blob)(?:/|%2f)[^\s"']+`)                                                      // ref/... blob/<hash> (raw or URL-enc)
	reIssueMAC      = regexp.MustCompile(`\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b`)                                                   // Wi-Fi/BT MAC
	reIssueEmail    = regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)
	reIssueSSID     = regexp.MustCompile(`(?i)(ssid[=:\s]+)("?)[^\s"']+`)                             // ssid=<name>
	reIssueHex      = regexp.MustCompile(`\b[0-9a-fA-F]{24,}\b`)                                      // sha256 refs / hashes / hmacs
	reIssueB64      = regexp.MustCompile(`\b[A-Za-z0-9+/_\-]{40,}={0,2}`)                             // blind tokens / vouchers / sigs
	reIssuePhone    = regexp.MustCompile(`\+\d[\d()\s.\-]{7,}\d|\(\d{3}\)[\s.\-]*\d{3}[\s.\-]*\d{4}`) // separator-formatted phone numbers (e.g. a note "call +1 415-555-0123"); keys on +/parens so it never eats a timestamp
	reIssueDigits   = regexp.MustCompile(`\b\d{7,}\b`)                                                // phone numbers (and big counts)
	// #87 (NWP-20260903-18): an Android build FINGERPRINT, anchored to a WHOLE value.
	//
	// brand/product/device:release/id/INCREMENTAL:type/tags -- e.g.
	// google/lynx/lynx:17/CP2A.260605.012/2026090202:userdebug/release-keys. The incremental slot is our
	// 10-digit BUILD_NUMBER, and reIssueDigits above rewrites it to <num>, so every ticket has been
	// hiding the one fact it most needs to carry. See statusValue for why matching the SHAPE is what
	// makes passing it through safe, and why this is NOT an allowlist.
	reIssueBuildFp = regexp.MustCompile(`\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:(?:user|userdebug|eng)/[A-Za-z0-9._,-]+\z`)

	// DIA-20260807-11: redact the profile name by POSITION, not by knowing its value.
	//
	// The literal-secret pass below can only remove the name it was TOLD, and buildIssueReport tells it
	// exactly one: the LIVE profile's. Every other identity that ever used this handset therefore passed
	// through untouched -- into the on-screen "View what's sent" preview and into the uploaded body. On lynx
	// 2026-08-07 a single grep of roam.log recovered EIGHT distinct profile names spanning days, because
	// nothing then trimmed these logs (log_scrub now keeps a 1 MiB tail at every reap and boot, NWP-20261017-01).
	//
	// We own both log formats, so the name sits in a fixed place: roamd writes `[roamd] <VERB> <name>`, and
	// the daemon writes it %q-quoted inside `[logind] ...`. Match the POSITION and the value stops mattering.
	// *(NWP-20261008-09: roamd and mediad now write the name quoted and escaped, through qn, and the one-word
	// position rules gave way to the rules below, which also heal what lines written before still hold.)*
	//
	// NWP-20261008-09: the name rules, in order -- the same rules, in the same order, as log_scrub's LOG_SCRUB_SED
	// in nowhere_roamd.sh, whose comment gives the reason for each; each one is spelled as the shell spells it, so
	// log_scrub_fuzz_test.go can hold the two to the same output on generated names, and report_issue_names_test.go
	// to the same shapes. quoted rules skip [restore] lines (reIssueRestoreLine), as the shell's `/^\[restore\]/!`
	// does: `[restore] skip %q` quotes FILE PATHS, which are what make a broken restore diagnosable.
	issueNameRules = []struct {
		re     *regexp.Regexp
		rep    string
		quoted bool
	}{
		// 1. old lines whose name a quote could derail, anchored at the line start (and at its end where it has a fixed one)
		{regexp.MustCompile(`^(\[logind\] export(?:-media)? ).*(: sealed [0-9]+ bytes -> ref/export/).*( \(blob [0-9a-f]+\))$`), `${1}"<name>"${2}<name>${3}`, false},
		{regexp.MustCompile(`^( *retry [A-Za-z ]*ref/export/).*( \([0-9]+/[0-9]+\): )`), "${1}<name>${2}", false},
		{regexp.MustCompile(`^( *retry [A-Za-z ]*ref/export/)(?:[^<]|<[^n]|<n[^a]|<na[^m]|<nam[^e]|<name[^>]|<name>[^ ]|<name> [^(]).*`), "${1}<name>", false},
		{regexp.MustCompile(`^(\[logind\] export(?:-media)? ).*(: cap-flush: gateway returned no write cap for ref/export/).*`), `${1}"<name>"${2}<name>`, false},
		{regexp.MustCompile(`^(\[logind\] export(?:-media)? ).*(: cap-flush: the gateway listed a POINTER as already present \(ref/export/).*(\) -- only content-)`), `${1}"<name>"${2}<name>${3}`, false},
		{regexp.MustCompile(`^(\[roamd\] fido2 profile ).*( -> (?:adopting|NFC-first|requesting))`), `${1}"<name>"${2}`, false},
		{regexp.MustCompile(`^(\[roamd\] fido2-enroll (?:OK|FAILED) for ).*( (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) )`), `${1}"<name>"${2}`, false},
		// 2. quoted tokens, escape-aware; then an export or pay-rent line the previous scrub split after its name token
		{reIssueQuotedTok, `"<name>"`, true},
		{regexp.MustCompile(`^(\[logind\] (?:export(?:-media)?|pay-rent) )"<name>"(?:[^:]|:[^ ]).*`), `${1}"<name>"`, false},
		// 3. what the previous scrub left of a name holding a quote: remainders ending in a backslash, and an odd quote
		{regexp.MustCompile(`"<name>"(?:[^"]*\\"<name>")+`), `"<name>"`, true},
		{regexp.MustCompile(`^([^"]*)"<name>"(?:[^"]*"[^"]*")*[^"]*"([^"]*)$`), `${1}"<name>"${2}`, true},
		// 4. old bare names, per verb, to the LAST of the texts that verb printed after a name
		{regexp.MustCompile(`(\[roamd\] IN )(?:[^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| NEEDKEY| -> user| BLANK)`), "${1}<name>${2}", false},
		{regexp.MustCompile(`(\[roamd\] GRANT )(?:[^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #)`), "${1}<name>${2}", false},
		{regexp.MustCompile(`(\[roamd\] OUT )(?:[^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| \(user| ERR-)`), "${1}<name>${2}", false},
		{regexp.MustCompile(`(\[mediad\] start )(?:[^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).* -> user`), "${1}<name> -> user", false},
		// 5. any export key still unquoted, [restore] lines exempt (reIssueRefTok later turns the rest of a ref into
		//    <ref>; on a [restore] path it runs after the literal pass, so the live name is still found whole there)
		{regexp.MustCompile(`(ref(?:/|%2[Ff])export(?:/|%2[Ff]))[^ "&?]+`), "${1}<name>", true},
		// 6. the old ssaid seed prefix (DIA-20260815-12)
		{regexp.MustCompile(`(seedssaid staged )[0-9A-Fa-f]+\.\.`), "${1}<redacted>..", false},
	}
	// reIssueQuotedTok is the escape-aware quoted rule: %q (the daemon, logProfile) and qn (roamd, mediad) escape `"`
	// and `\` inside the name, and the old `"[^"\n]*"` stopped at an escaped quote -- `profile "ja\"ne"` went out as
	// `"<name>"ne"`, live name included (NWP-20261008-09). billing.go's gatewayReason relies on it.
	reIssueQuotedTok = regexp.MustCompile(`"(?:[^"\\\n]|\\.)*"`)

	// DIA-20260807-14: the one shape whose quotes are NOT a name. `[restore] skip "pkg/path"` and
	// `[restore] rejected unsafe tar entry "..."` quote FILE PATHS, and those are what make a broken restore
	// diagnosable -- DIA-20260806-10 was found through them. Everything else quoted is treated as a name.
	reIssueRestoreLine = regexp.MustCompile(`^\s*\[restore\]`)

	// NWP-20261011-36: the resolver's LEGACY egress line, `[resolver] egress iface=... dns=[<addr:port> ...]
	// src=...`, carried every network's own resolver addresses. egressLine now writes resolvers=[...] with those
	// as placeholders, but devices hold the old lines, so the list goes whole: greedy to the last `]` before
	// ` src=` (or the end, for lines written before src= existed, DIA-20260720-02), because a v6 entry is itself
	// bracketed (`[2001:db8::53]:53`) and a `[^\]]*` list would stop inside it. The prefix is lazy so the FIRST
	// ` dns=[` starts the match, as in sed. log_scrub's LOG_SCRUB_DNS_SED is the same rule. It is NOT one of
	// issueNameRules: those mirror LOG_SCRUB_SED rule for rule (log_scrub_fuzz_test.go), and this mirrors a
	// separate program.
	reIssueLegacyDNS = regexp.MustCompile(`^(\[resolver\] egress .*?) dns=\[.*\]( src=|$)`)
)

// scrubIssueLine returns the redacted line and whether to KEEP it. secrets are literal strings (e.g. the live
// profile name) redacted verbatim before the pattern pass. Drop wins over redact.
func scrubIssueLine(line string, secrets []string) (string, bool) {
	low := strings.ToLower(line)
	for _, k := range issueDropKeywords {
		if strings.Contains(low, k) {
			return "", false
		}
	}
	// DIA-20260807-14: DEFAULT-DENY on quoted tokens, and only for LOG LINES -- never for the user's note,
	// which redactIssueSecrets also serves and where blanket-redacting quotes would mangle what they typed.
	//
	// Three rounds of enumerating name POSITIONS each missed shapes the device then found: the daemon's
	// `[logind] "x"`, then `profile "x"` from agent output arriving with no bracket tag, then
	// `mediad: serving ... for "x"` plus a SECOND quoted token on one line that the first-match rule skipped.
	// Enumerating is the wrong structure. In OUR logs a quoted token is a name until proven otherwise, and the
	// only proven exception is the [restore] file-path form above.
	out := redactIssueSecrets(reIssueLegacyDNS.ReplaceAllString(applyIssueNameRules(line), "${1} dns=[<redacted>]${2}"), secrets)
	return out, true
}

// applyIssueNameRules runs issueNameRules over one line, in order, with the quoted rules skipping [restore] lines:
// what log_scrub's sed program does to it, and log_scrub_fuzz_test.go holds the two to the same output.
func applyIssueNameRules(line string) string {
	restore := reIssueRestoreLine.MatchString(line)
	for _, r := range issueNameRules {
		if r.quoted && restore {
			continue
		}
		line = r.re.ReplaceAllString(line, r.rep)
	}
	return line
}

// statusValue scrubs ONE caller-supplied status value (#87, NWP-20260903-18).
//
// THE BUG IT FIXES. The chooser gathers the Android-side facts the confined daemon cannot reach and sends
// them as status; os_build is Build.FINGERPRINT. Every value here goes through redactIssueSecrets, whose
// last pass -- reIssueDigits, the plain-digit phone-number backstop -- rewrites any run of 7+ digits to
// <num>. A fingerprint carries exactly one such run: its INCREMENTAL slot, which is our 10-digit
// BUILD_NUMBER. So every support ticket ever filed has said .../CP2A.260605.012/<num>:user/release-keys,
// hiding WHICH IMAGE the device runs -- on a locked user build, where there is no adb and no logcat, the
// issue reporter is the only diagnostic channel there is, and this was the first question it could not
// answer. (Cost, felt directly on 2026-09-03: identifying a dev device build took a build-host dig and a
// binary hash, and three merged records had cited a build that never existed -- NWP-20260903-17.)
//
// WHY THIS IS NOT AN ALLOWLIST, and does not weaken the rule it sits under. The rule at the call site is
// "never trust free-form in". This does not trust the KEY (a value under os_build is scrubbed like any
// other unless it earns the exemption) and it does not trust the CALLER. It trusts a SHAPE, verified
// here: reIssueBuildFp is anchored A...z, so the ENTIRE value must be a well-formed fingerprint --
// eight structural fields, a build type from a closed set, and no whitespace anywhere. A value that
// matches is by construction build metadata and nothing else; a value that does not is still free-form
// and is still fully scrubbed. The two surfaces where an untrusted party writes the text -- the user note
// and the log lines -- do NOT come through here and are untouched by this change.
//
// The literal-secret (profile-name) pass is deliberately NOT applied to a matched fingerprint: it would
// mangle the build of any device whose profile happens to be named after a fingerprint token (a profile
// called "lynx" would render google/<name>/<name>:17/...), and it protects nothing, since a fingerprint
// reads identically whatever the profile is called and so cannot disclose it.
func statusValue(v string, secrets []string) string {
	if reIssueBuildFp.MatchString(v) {
		return v
	}
	return redactIssueSecrets(v, secrets)
}

// redactIssueSecrets applies the literal-secret pass then the generic pattern pass. Used for log lines AND the
// note (the note is never line-dropped -- the user typed it on purpose -- but it is still pattern-scrubbed so an
// accidentally-pasted number/token/email does not leak).
func redactIssueSecrets(s string, secrets []string) string {
	for _, sec := range secrets {
		if len(sec) < 3 { // never redact 1-2 char "secrets" -- would shred normal text
			continue
		}
		// case-insensitive literal replace
		re := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(sec))
		s = re.ReplaceAllString(s, "<name>")
	}
	// NB the structural name passes moved to scrubIssueLine (DIA-20260807-14): they are LOG-LINE rules, and
	// this function also scrubs the user's free-text note, where redacting every quoted token would mangle
	// what they deliberately typed.
	s = reIssueKV.ReplaceAllString(s, "${1}${2}<redacted>")
	s = reIssueAWS.ReplaceAllString(s, "<token>")
	s = reIssueURLQuery.ReplaceAllString(s, "$1?<redacted>")
	s = reIssueRefTok.ReplaceAllString(s, "<ref>")
	s = reIssueMAC.ReplaceAllString(s, "<mac>")
	s = reIssueEmail.ReplaceAllString(s, "<email>")
	s = reIssueSSID.ReplaceAllString(s, "${1}<ssid>")
	s = reIssueHex.ReplaceAllString(s, "<hex>")
	s = reIssueB64.ReplaceAllString(s, "<token>")
	s = reIssuePhone.ReplaceAllString(s, "<num>") // before the plain-digit pass: catch separator-formatted numbers whole
	s = reIssueDigits.ReplaceAllString(s, "<num>")
	return s
}

// avcDenials returns recent SELinux denials, oldest first, capped at max.
//
// DIA-20260806-04: our four logs record the CONSEQUENCE of a denial ("Permission denied", "mkdir parent
// failed", a 2-chunk seal) and never the denial itself -- but a policy rule needs scontext, tcontext, tclass
// and the permission, which live only in the audit stream. That is the difference between a report saying
// "the roam is broken" and one that names the missing allow line.
//
// Device-proven need: frankel (NW-55130e19af8c, 2026-08-06) sealed a 2-chunk = EMPTY vault and restored
// nothing, and the report could not say why. frankel is a `user` build -- the first fully ENFORCING one --
// while every on-device proof before it ran permissive, which is exactly how this reached a release image
// unseen. Enforcing builds are where denials matter most and are also where we have no adb.
//
// Two sources, because neither is guaranteed to be reachable from this domain: logcat's auditd buffer, then
// the kernel ring buffer. Best-effort by design -- an unreadable source contributes nothing and must never
// fail the report, which is a user-facing action.
// diagSource records whether ONE diagnostic source could be read. DIA-20260811-10: the whole point is that
// "we found nothing" and "we could not look" stop being the same output. err == "" means the source was read.
type diagSource struct {
	name string
	err  string
}

func (s diagSource) ok() bool { return s.err == "" }

// readDiag runs one best-effort collector and classifies the outcome. A non-zero rc, a missing binary and an
// empty result are all recorded rather than swallowed -- swallowing them is exactly the bug DIA-20260811-10
// fixes. Output is still returned on error: a partial read is better than nothing.
func readDiag(name string, argv ...string) ([]byte, diagSource) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, name, argv...).Output()
	s := diagSource{name: name}
	switch {
	case err != nil:
		s.err = err.Error()
	case len(b) == 0:
		s.err = "produced no output"
	}
	return b, s
}

// NWP-20260908-12: ABSOLUTE PATHS. These were bare names resolved through $PATH, and the login daemon's
// PATH does not contain /system/bin -- so every attempt died at
//
//	logcat (exec: "logcat": executable file not found in $PATH)
//
// before any permission was ever consulted. Both binaries exist and are world-executable on device
// (/system/bin/logcat is a real 150 KB binary; /system/bin/dmesg is a toybox symlink).
//
// ⚠ THIS ALSO MEANS THE DOCUMENTED CAUSE BELOW HAS NEVER BEEN TESTED. avcSection says the section is empty
// because "logcat needs logd read access and dmesg needs CAP_SYSLOG and the login daemon's domain (nowhere)
// has neither on a user build". That may well be true, but it is not what the fielded evidence shows: NW-6c994557f63f
// (frankel, 2026090802) reports an exec failure, not a denial. The exec never got far enough to find out.
// Leave that paragraph in place -- it is a real hypothesis -- but the next ticket is the first that can
// actually confirm or refute it. The collector runs in the login daemon (handleReportIssue ->
// buildIssueReportWith -> avcDenials), whose domain is nowhere (nowhere.rc), not roamd's endospore_priv; whether
// that domain may read logd's buffers or holds CAP_SYSLOG has not been run on a user build.
var avcSourceCmds = [][]string{
	{"/system/bin/logcat", "-d", "-b", "all", "-s", "auditd:*"},
	{"/system/bin/dmesg"},
}

// readDiagFn is the test seam avcDenials execs through; production never reassigns it.
var readDiagFn = readDiag

func avcDenials(max int) ([]string, []diagSource) {
	var out []string
	var srcs []diagSource
	seen := map[string]bool{}
	add := func(raw []byte) {
		for _, ln := range strings.Split(string(raw), "\n") {
			if !strings.Contains(ln, "avc:") || !strings.Contains(ln, "denied") {
				continue
			}
			ln = strings.TrimSpace(ln)
			if ln == "" || seen[ln] {
				continue // the kernel repeats identical denials; one copy is all a rule needs
			}
			seen[ln] = true
			out = append(out, ln)
		}
	}
	for _, c := range avcSourceCmds {
		b, s := readDiagFn(c[0], c[1:]...)
		srcs = append(srcs, s) // record the OUTCOME, not just the bytes (DIA-20260811-10)
		add(b)
		if len(out) >= max {
			break // enough denials; the remaining sources are deliberately NOT attempted, so not recorded
		}
	}
	if len(out) > max {
		out = out[len(out)-max:] // newest wins: the denial we are chasing is the most recent
	}
	return out, srcs
}

// avcSection renders the denial section so it is ALWAYS present and always says which of the two states it is
// in. DIA-20260811-10: before this, buildIssueReport did `if len(den) > 0 { logs["avc"] = ... }`, so a total
// failure to read produced a report with no "avc" key -- byte-identical to a device with a clean policy. That
// was not theoretical: across ALL SIX tickets ever filed on the beta gateway, not one carried a single denial
// line, because logcat needs logd read access and dmesg needs CAP_SYSLOG and the login daemon's domain
// (nowhere), where the collector runs, may have neither on a user build -- untested since the exec failure
// was fixed (NWP-20260908-12). We shipped a denial channel, and it returned nothing, and nothing said so. Same family as #42
// (a dontaudit-ed mount denial silently killed on-demand media) and #197 (silence read as success).
func avcSection(den []string, srcs []diagSource, secrets []string) []string {
	var bad []string
	for _, s := range srcs {
		if !s.ok() {
			bad = append(bad, s.name+" ("+s.err+")")
		}
	}
	var head []string
	switch {
	case len(srcs) > 0 && len(bad) == len(srcs):
		// The load-bearing line. An empty section MUST NOT be read as "no denials".
		head = append(head, "avc: NO source could be read -- "+strings.Join(bad, "; ")+
			" -- denials were NOT collected; this does NOT mean the device is denial-free")
	case len(bad) > 0:
		head = append(head, "avc: partial -- unreadable: "+strings.Join(bad, "; "))
	}
	if len(den) == 0 && len(bad) == 0 {
		head = append(head, "avc: sources readable, no denials in the captured window")
	}
	return append(scrubIssueLines(head, secrets), scrubIssueLines(den, secrets)...)
}

// pstoreDir is where prevBootTail reads the previous boot's ramoops. A var only so a test can point it at a temp
// dir (NWP-20261126-15); production never reassigns it.
var pstoreDir = "/sys/fs/pstore"

// prevBootTail returns the tail of the PREVIOUS boot's kernel log from pstore/ramoops. DIA-20260811-10: the
// four /data/nowhere logs survive a reboot (they are on f2fs -- lynx's login.log reaches back 16 days and many
// reboots), but logcat is cleared at boot and dmesg is the NEW boot's ring, so after a reboot the report
// carries nothing about what actually happened. pstore does survive, and it is where a kernel panic or a
// watchdog reboot leaves its evidence. Concrete cost of not having it: frankel rebooted 2026-08-11 12:15:19
// with no logout in flight and a periodic seal that had completed cleanly 60s earlier -- the daemon was
// exonerated and nothing in the report could say what DID reboot the phone.
//
// Best-effort like everything else here, but NEVER silently: an unreadable pstore is reported, because the
// whole lesson of this change is that absence must be legible. Tail, not head -- a panic is at the end.
func prevBootTail(maxLines int) ([]string, []diagSource) {
	ents, err := os.ReadDir(pstoreDir)
	if err != nil {
		return nil, []diagSource{{name: "pstore", err: err.Error()}}
	}
	var out []string
	var srcs []diagSource
	for _, e := range ents {
		n := e.Name()
		// console-ramoops-* is the console tail; dmesg-ramoops-* is a captured panic. Both are worth having.
		if !strings.HasPrefix(n, "console-ramoops") && !strings.HasPrefix(n, "dmesg-ramoops") {
			continue
		}
		raw, rerr := os.ReadFile(filepath.Join(pstoreDir, n))
		s := diagSource{name: n}
		if rerr != nil {
			s.err = rerr.Error()
		} else if len(raw) == 0 {
			s.err = "empty"
		}
		srcs = append(srcs, s)
		if rerr != nil {
			continue
		}
		lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
		if len(lines) > maxLines {
			lines = lines[len(lines)-maxLines:]
		}
		out = append(out, "--- "+n+" ---")
		out = append(out, lines...)
	}
	if len(srcs) == 0 {
		srcs = append(srcs, diagSource{name: "pstore", err: "no ramoops entries present"})
	}
	return out, srcs
}

// otaStatusMarker reports the daemon's OTA view for an issue report (NWP-20260824-03). Ages are WALL-clock
// seconds, which is the point: the monotonic clock froze across suspend and took the staleness test with it,
// so an age measured that way would have read "a couple of minutes" after half an hour asleep. -1 means never.
func otaStatusMarker() map[string]string {
	otaCacheMu.Lock()
	latest, avail, at, lastTry, lastErr := otaCacheLatest, otaCacheAvail, otaCacheAt, otaLastTry, otaLastErr
	refreshing := otaRefreshing
	otaCacheMu.Unlock()

	age := func(t time.Time) string {
		if t.IsZero() {
			return "-1"
		}
		return strconv.FormatInt(int64(time.Since(t).Seconds()), 10)
	}
	if latest == "" {
		latest = "none"
	}
	if lastErr == "" {
		lastErr = "none"
	}
	store := "no"
	if storeConfigured() {
		store = "yes"
	}
	return map[string]string{
		"ota_latest":         latest,
		"ota_avail":          strconv.FormatBool(avail),
		"ota_checked_age_s":  age(at),
		"ota_last_try_age_s": age(lastTry),
		"ota_last_err":       lastErr,
		"ota_refreshing":     strconv.FormatBool(refreshing),
		"ota_store":          store,
		"ota_running":        runningOtaVersion(),
	}
}

// The kernel's per-boot identity. A var so tests can point it at a fixture (there is no /proc on the test
// host that says what the test needs it to). The per-boot CLOCK is bootUptime (main.go), which is sysinfo(2)
// and not a /proc path: the daemon's domain is denied proc_uptime on an enforcing build (NWP-20261013-02).
var procBootIDPath = "/proc/sys/kernel/random/boot_id"

// readBootID returns this boot's boot_id, or "unknown" when it cannot be read. One reader for the two
// consumers that must agree on the spelling: bootMarker (the report's own boot) and recordRebootReason
// (the boot a reboot was requested in) -- last_reboot_pending is their equality.
func readBootID() string {
	b, err := os.ReadFile(procBootIDPath)
	if err != nil {
		return "unknown"
	}
	s := strings.TrimSpace(string(b))
	if s == "" {
		return "unknown"
	}
	return s
}

// bootMarker identifies the boot this report describes: which boot (boot_id) and how old it is (uptime_s).
// See DIA-20260811-10. boot_id is omitted when unreadable: it is compared, not read, and a placeholder would
// have to be excluded from every comparison. uptime_s SELF-DECLARES an unreadable source instead
// (NWP-20260904-10), matching avc and prev_boot: the first cut omitted it silently, and it was absent from
// all three of one owner's reports before anyone noticed -- an omitted status field turned out to be exactly
// as mistakable for "nothing to say" as an omitted log section was.
//
// uptime_s is a decimal INTEGER ("12345") since NWP-20261013-02: bootUptime's sysinfo(2) seconds, rounded UP,
// so up to 1 s high. It used to be /proc/uptime's first field verbatim ("12345.67"), which the daemon's
// domain is denied on an enforcing build -- so on a locked user build it never carried a number at all, only
// the "unreadable: ..." self-declaration. A reader that parses it as a float still parses it.
func bootMarker() map[string]string {
	out := map[string]string{}
	if id := readBootID(); id != "unknown" {
		out["boot_id"] = id
	}
	if up, err := bootUptime(); err != nil {
		out["uptime_s"] = "unreadable: " + err.Error()
	} else {
		out["uptime_s"] = strconv.FormatInt(up, 10)
	}
	return out
}

// rebootLandingWindowS bounds how long a reboot the daemon (or otad) requested may take to land in a running
// boot before the record is judged NOT to describe this boot. The gap measured is request-to-boot-start, so
// it does not grow while the phone sits at the gate; a real reboot lands in a small fraction of this, and the
// window is wide on purpose so a slow boot never reads as a power cycle.
const rebootLandingWindowS = 600

// lastRebootMarker reads the record rebootNow (and nowhere_otad.sh) leave before rebooting -- see
// recordRebootReason for the shape -- and renders it as status keys (NWP-20260904-10):
//
//	last_reboot_reason     the text, device-scope by contract (rebootNow), scrubbed again by the caller
//	last_reboot_age_s      wall-clock seconds since it was recorded
//	last_reboot_boot_id    the boot the reboot was requested in
//	last_reboot_pending    "true" when that boot is THIS boot: recorded, but the reboot never happened.
//	                       "false" when this is a later boot; "unknown" when either boot_id is.
//	last_reboot_to_boot_s  seconds from the request to the START of this boot (age minus uptime); negative
//	                       means the record was written in this boot. Omitted when uptime is unreadable.
//	last_reboot_stale      "true" when that gap exceeds rebootLandingWindowS: this boot was NOT started by
//	                       the recorded reboot. A reboot the daemon never saw came between -- a power
//	                       cycle, the chooser's watchdog dpm.reboot, a kernel panic -- and last_reboot_reason
//	                       describes an OLDER reboot than the one the reporter just experienced. The
//	                       record cannot know that on its own (those issuers cannot write /data/nowhere,
//	                       and a power cycle writes nothing), which is why the report has to say it.
//
// No file -> no keys (nothing was recorded, and a reader must not mistake silence for a reason). A file that
// is present but unreadable or malformed self-declares under last_reboot_reason, like uptime_s.
func lastRebootMarker() map[string]string {
	b, err := os.ReadFile(lastRebootPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return map[string]string{"last_reboot_reason": "unreadable: " + err.Error()}
	}
	line, _, _ := strings.Cut(string(b), "\n")
	f := strings.SplitN(line, "\t", 3)
	if len(f) != 3 {
		return map[string]string{"last_reboot_reason": fmt.Sprintf("unparseable: %d of 3 fields", len(f))}
	}
	at, err := strconv.ParseInt(f[0], 10, 64)
	if err != nil {
		return map[string]string{"last_reboot_reason": "unparseable: bad timestamp"}
	}
	pending := "unknown"
	if cur := readBootID(); f[1] != "unknown" && cur != "unknown" {
		pending = strconv.FormatBool(f[1] == cur)
	}
	age := time.Now().Unix() - at
	out := map[string]string{
		"last_reboot_reason":  f[2],
		"last_reboot_age_s":   strconv.FormatInt(age, 10),
		"last_reboot_boot_id": f[1],
		"last_reboot_pending": pending,
	}
	if up, err := bootUptime(); err == nil {
		gap := age - up
		out["last_reboot_to_boot_s"] = strconv.FormatInt(gap, 10)
		out["last_reboot_stale"] = strconv.FormatBool(gap > rebootLandingWindowS)
	}
	return out
}

// bootPropTimeout bounds one getprop read: a report is a user-facing action and must not wait on a hung child.
const bootPropTimeout = 2 * time.Second

// readBootProp reads one Android system property. A var so tests replace it. The ABSOLUTE path is deliberate, as
// in main.go's init.svc.* reads: the daemon's PATH may lack /system/bin.
var readBootProp = func(prop string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), bootPropTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/system/bin/getprop", prop).Output()
	return string(out), err
}

// bootReasonUnread is the value of a boot reason key whose read failed or came back empty. getprop prints an empty
// line and exits 0 for a property the caller's SELinux domain may not read, so empty is never "no reboot".
const bootReasonUnread = "unread"

// bootReasonHistoryCap bounds boot_reason_history in bytes, after the scrub.
const bootReasonHistoryCap = 512

// bootReasonMarker returns Android's own record of why the device booted, raw (the caller scrubs and caps it):
// boot_reason (ro.boot.bootreason, the bootloader's reason for THIS boot), boot_reason_last (sys.boot.reason.last,
// bootstat's reason for the last boot) and boot_reason_history (persist.sys.boot.reason.history, one line per boot,
// joined with "; ").
func bootReasonMarker() map[string]string {
	read := func(prop string) string {
		v, err := readBootProp(prop)
		v = strings.TrimSpace(v)
		if err != nil || v == "" {
			return bootReasonUnread
		}
		return v
	}
	return map[string]string{
		"boot_reason":         read("ro.boot.bootreason"),
		"boot_reason_last":    read("sys.boot.reason.last"),
		"boot_reason_history": joinBootHistory(read("persist.sys.boot.reason.history")),
	}
}

// joinBootHistory puts the history's lines on one line, joined with "; ", dropping blank lines.
func joinBootHistory(v string) string {
	var lines []string
	for _, l := range strings.Split(v, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	return strings.Join(lines, "; ")
}

// capBytes cuts s to at most n bytes, backing off to a rune start so the cut never splits a UTF-8 sequence.
func capBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// anrDir is where the framework writes ANR traces; a var only so a test can point it at a temp dir.
var anrDir = "/data/anr"

// anrSeenFile is the sign-in snapshot of anrDir's trace names, in the state dir beside uiderrors.floor.
const anrSeenFile = "anr.seen"

// recordAnrSeen snapshots the NAMES of the traces already in anrDir, once, where a new session begins. /data/anr
// is shared by every session of the boot and nothing records which session wrote a file, so a report leaves out
// every name listed here (no clock is compared: see uiderrorsTail on why an offset and not a date). ENOENT is an
// EMPTY snapshot (no trace existed, so every later one is this session's). Any other failure removes the old
// snapshot -- a stale one is worse than none -- and the session's reports then carry no anr section. The names are
// timestamps, never packages; the file lives in the RAM state dir and is sent nowhere.
func recordAnrSeen(dest string) {
	path := filepath.Join(dest, anrSeenFile)
	ents, err := os.ReadDir(anrDir)
	var names []string
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		os.Remove(path)
		fmt.Fprintf(os.Stderr, "[logind] anr snapshot not taken (%v) -- this session's issue reports carry no anr section\n", err)
		return
	}
	for _, e := range ents {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	body := ""
	if len(names) > 0 {
		body = strings.Join(names, "\n") + "\n"
	}
	tmp := path + ".tmp"
	err = os.WriteFile(tmp, []byte(body), 0o600)
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		os.Remove(path)
		fmt.Fprintf(os.Stderr, "[logind] anr snapshot not taken (%v) -- this session's issue reports carry no anr section\n", err)
	}
}

// readAnrSeen is recordAnrSeen's snapshot: nil when absent or unreadable, an empty non-nil map for an empty one.
func readAnrSeen(dest string) map[string]bool {
	raw, err := os.ReadFile(filepath.Join(dest, anrSeenFile))
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	for _, ln := range strings.Split(string(raw), "\n") {
		if ln != "" {
			seen[ln] = true
		}
	}
	return seen
}

// anrHeaders returns the HEADER lines of the newest ANR traces. /data/anr is shared by every session of a boot (the
// boot sweep empties it at the next boot, NWP-20261015-21, and nothing empties it at a sign-out).
// Headers only, deliberately: a full trace is every thread of every process, runs to megabytes, and would evict
// the nowhere logs under maxIssueReportBytes. The header carries what triage needs -- which process, what reason.
// Newest first, because the ANR being reported is the last one.
//
// seen is the snapshot recordAnrSeen took when this session began: a trace named in it is an earlier session's (or
// this session's own restore) and is left out BEFORE it is read. nil -- no snapshot -- returns nothing at all.
// The skipped files are never counted, named or logged: a count would tell this session an earlier one had ANRs.
func anrHeaders(dir string, seen map[string]bool, maxLines int) ([]string, []diagSource) {
	if seen == nil {
		return nil, nil // no snapshot: fail closed
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, []diagSource{{name: "anr", err: err.Error()}}
	}
	type ent struct {
		path string
		mod  time.Time
	}
	var files []ent
	for _, e := range ents {
		if e.IsDir() || seen[e.Name()] {
			continue
		}
		if fi, ferr := e.Info(); ferr == nil {
			files = append(files, ent{filepath.Join(dir, e.Name()), fi.ModTime()})
		}
	}
	if len(files) == 0 {
		return nil, []diagSource{{name: "anr", err: "no traces present"}}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.After(files[j].mod) })
	var out []string
	var srcs []diagSource
	for _, f := range files {
		if len(out) >= maxLines {
			break
		}
		raw, rerr := os.ReadFile(f.path)
		s := diagSource{name: filepath.Base(f.path)}
		if rerr != nil {
			s.err = rerr.Error()
			srcs = append(srcs, s)
			continue
		}
		srcs = append(srcs, s)
		out = append(out, "--- "+filepath.Base(f.path)+" ---")
		// The header is the block before the first thread dump ("----- pid ..." / "DALVIK THREADS").
		for _, ln := range strings.Split(string(raw), "\n") {
			t := strings.TrimSpace(ln)
			if strings.HasPrefix(t, "DALVIK THREADS") || strings.HasPrefix(t, "\"main\"") {
				break
			}
			if t == "" {
				continue
			}
			out = append(out, t)
			if len(out) >= maxLines {
				break
			}
		}
	}
	return out, srcs
}

// anrSection renders anrHeaders the same always-honest way. Unlike avc/prev_boot this section is OMITTED when
// there is simply nothing to say (no traces, directory absent) -- an absent ANR dir is the normal, healthy case
// and a permanent "no traces" line in every report would be noise. An unreadable dir IS reported.
func anrSection(lines []string, srcs []diagSource, secrets []string) []string {
	var bad []string
	for _, s := range srcs {
		if !s.ok() && s.err != "no traces present" {
			bad = append(bad, s.name+" ("+s.err+")")
		}
	}
	if len(lines) == 0 && len(bad) == 0 {
		return nil // nothing to report and nothing hidden -- stay quiet
	}
	var head []string
	if len(bad) > 0 {
		head = append(head, "anr: unreadable: "+strings.Join(bad, "; "))
	}
	return append(scrubIssueLines(head, secrets), scrubIssueLines(lines, secrets)...)
}

// prevBootSection renders prevBootTail the same always-present, always-honest way as avcSection.
func prevBootSection(lines []string, srcs []diagSource, secrets []string) []string {
	var bad []string
	for _, s := range srcs {
		if !s.ok() {
			bad = append(bad, s.name+" ("+s.err+")")
		}
	}
	var head []string
	if len(lines) == 0 {
		head = append(head, "prev_boot: nothing collected -- "+strings.Join(bad, "; ")+
			" -- this does NOT mean the last boot was clean")
	} else if len(bad) > 0 {
		head = append(head, "prev_boot: partial -- unreadable: "+strings.Join(bad, "; "))
	}
	return append(scrubIssueLines(head, secrets), scrubIssueLines(lines, secrets)...)
}

// ---- uiderrors (NWP-20261010-06) -------------------------------------------------------------------------
//
// /data/system/uiderrors.txt is the package manager's critical-info log. Its `Destroying <dir> due to: <reason>`
// lines come from ONE writer: the app-data reconcile at a user start (AppDataHelper.reconcileAppsData), which
// deletes a per-user package dir it cannot match to an installed package. That is the destroy the shrink refusal
// of NW-cebeb51558fd / NW-db441ee766cb (a #de scope losing every large file mid-session) is suspected of, and the
// file is the one persistent record of it on a locked user build. ⚠ IT IS NOT A LOG OF EVERY DELETION: uninstall,
// clear-data and user removal delete app data without writing here (AOSP, from memory -- about 75% sure for all
// three), so an absent line proves nothing about those paths, and the section header says so.
//
// ⚠ THE LOGIN DAEMON CANNOT READ IT, AND THAT IS NOT WIDENED. The file is system_data_file (no file_contexts
// entry names it, and system_server creates it in /data/system, so it inherits the directory's type), and the
// `nowhere` domain holds no right on that type at all. Granting it would hand a network-facing daemon read on
// the whole of /data/system -- packages.xml, the per-user settings, the gatekeeper and lock-settings state --
// to collect one diagnostic file. So the roamd worker reads it on the READ-ONLY lane: on Endospore that is
// endospore_priv, which already holds system_data_file r_dir_perms/r_file_perms (endospore.te) for the per-user
// trees, and on Diaspore su:s0. Nothing new is granted anywhere.
//
// ⚠ ONLY THIS SESSION'S LINES LEAVE THE WORKER. /data survives power-off here (the amnesia removes USERS, not
// /data), nothing truncates the file, and user ids restart at 10 every boot -- so the file holds earlier renters'
// and earlier boots' destroys under the very uid this session has. Two filters, both applied in the worker:
//   - a FLOOR: the file's size when this session signed in, recorded by roamd's `in` op (uiderrorsFloor). The
//     file is append-only, so every byte past the floor was written during this session, whatever uid it names.
//     A date filter was the alternative and it cannot hold: the lines carry a locale-formatted, minute-resolution
//     local time with a two-digit year, and the device clock can move, so a reused uid's line from a few minutes
//     before sign-in would pass it. The offset cannot be fooled by a reused uid, a clock or a locale.
//   - a USER: of the lines past the floor, only those holding a per-user path of <uid> (/data/<tree>/<uid>/...,
//     or the same under /mnt/expand/<volume>) -- a line about user 0 or about
//     no user is counted, never shown.
//
// No floor (an offline sign-in, a session that began before this build, a worker that could not stat the file at
// sign-in) means NOTHING is shown: the report says it cannot separate this session's lines rather than guessing.
//
// uiderrorsTail is the worker half (`nowhere_agent uiderrorstail <floor> <uid>`); its reply is the protocol:
//
//	OK <size> <floor> <withheld> <uid>\n<lines>   read; <lines> are this session's, for <uid>
//	ABSENT                                       ENOENT with a zero floor: the framework never wrote it
//	ERR-NOFLOOR / ERR-NOUID / ERR-SHRUNK <why>   cannot tell this session's lines from anyone else's
//	ERR-READ <error>                             anything else -- most likely EACCES, a policy that denies it
//
// ABSENT is only claimed on ENOENT. A directory search the policy denies fails with EACCES, not ENOENT, so a
// denial cannot masquerade as "nothing was ever destroyed".
var uiderrorsPath = "/data/system/uiderrors.txt"

// uiderrorsFloorFile is the floor roamd's `in` op records in the state dir (uiderrors_floor_commit).
const uiderrorsFloorFile = "uiderrors.floor"

// forgetUiderrorsFloor drops both of the session's report floors (the uiderrors offset and the anr.seen snapshot)
// wherever a session ENDS, or begins without roamd's `in`. Without
// it a floor outlives its session -- handleLogout does not wipe the state dir -- and an offline sign-in, which
// records none, would read the previous session's offset and call those lines its own. Not at a cold lock (the
// same session resumes), a rotate or a promote (the same session continues), a re-armed logoff (ditto), or
// CLEAR-COLDLOCK (its one caller runs AFTER a fresh sign-in, so the floor there is the new session's).
func forgetUiderrorsFloor(dest string) {
	os.Remove(filepath.Join(dest, uiderrorsFloorFile))
	os.Remove(filepath.Join(dest, anrSeenFile))
}

// uiderrorsFloor is the file's size now, for roamd's `in` op to record as this session's floor. ENOENT is a
// floor of 0 (everything the framework writes from here on is this session's); any other error is returned, and
// roamd then records no floor at all.
func uiderrorsFloor(path string) (int64, error) {
	fi, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return fi.Size(), nil
}

func uiderrorsTail(path string, maxBytes int64, floorStr, uid string) string {
	floor, ferr := strconv.ParseInt(strings.TrimSpace(floorStr), 10, 64)
	if ferr != nil || floor < 0 {
		return "ERR-NOFLOOR no sign-in floor was recorded for this session, so its lines cannot be told from earlier sessions'\n"
	}
	if uid = strings.TrimSpace(uid); uid == "" || strings.Trim(uid, "0123456789") != "" {
		return "ERR-NOUID the request names no user, so no line can be attributed to this session\n"
	}
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			if floor == 0 {
				return "ABSENT\n"
			}
			return fmt.Sprintf("ERR-SHRUNK the file held %dB at sign-in and is gone now\n", floor)
		}
		return "ERR-READ " + err.Error() + "\n"
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "ERR-READ " + err.Error() + "\n"
	}
	size := fi.Size()
	if size < floor {
		return fmt.Sprintf("ERR-SHRUNK the file held %dB at sign-in and holds %dB now, so the sign-in offset no longer marks this session's lines\n", floor, size)
	}
	off := floor
	if size-off > maxBytes {
		off = size - maxBytes
	}
	buf := make([]byte, size-off)
	n, err := f.ReadAt(buf, off)
	if err != nil && !errors.Is(err, io.EOF) { // EOF: the file shrank after the Stat; what was read stands
		return "ERR-READ " + err.Error() + "\n"
	}
	body := buf[:n]
	if off > floor {
		// The bound cut mid-line: drop the fragment, so every line shown carries its own date. (At the floor
		// itself there is nothing to drop -- the file is append-only, so its size at sign-in is a line boundary.)
		if i := bytes.IndexByte(body, '\n'); i >= 0 {
			body = body[i+1:]
		}
	}
	// A per-user PATH, anchored at its root -- /data/<tree>/<uid> or /mnt/expand/<volume>/<tree>/<uid> -- never a
	// bare "/<uid>/": the line's own date prefix (M/d/yy, "10/10/26") holds "/10/", which matched every line.
	mine := regexp.MustCompile(`(?:^|[\s:=(])/(?:data|mnt/expand/[^/\s]+)/[a-z_]+/` + uid + `(?:/|[\s:;,)]|$)`)
	var kept []string
	withheld := 0
	for _, ln := range strings.Split(string(body), "\n") {
		if strings.TrimSpace(ln) == "" {
			continue
		}
		if mine.MatchString(ln) {
			kept = append(kept, ln)
		} else {
			withheld++
		}
	}
	return fmt.Sprintf("OK %d %d %d %s\n%s", size, floor, withheld, uid, strings.Join(kept, "\n"))
}

// uiderrorsWait bounds how long a report waits for the worker. The report is a user-facing action (the
// preview the chooser reads within 90s), so a wedged worker must cost a line saying so, not the report.
var uiderrorsWait = 20 * time.Second

// uiderrorsWorker is the RO-lane request; a var so a test can prove handleReportIssue really asks it.
var uiderrorsWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "uiderrors", name, "", uid, "", nil)
}

// fetchUiderrors asks the RO-lane worker for this session's lines. The worker op runs on in its goroutine if the
// wait expires; it only reads, and the RO lane's own slot keeps it from piling up.
func fetchUiderrors(dest, name, uid string) string {
	if name == "" || uid == "" {
		return "ERR-NOSESSION the session marker names no profile or no user id, and the worker filters by that user, so nothing can be asked"
	}
	ch := make(chan string, 1)
	goSafe("uiderrors", func() { ch <- uiderrorsWorker(dest, name, uid) })
	select {
	case r := <-ch:
		return r
	case <-time.After(uiderrorsWait):
		return fmt.Sprintf("ERR-TIMEOUT the worker did not answer within %s", uiderrorsWait)
	}
}

// uiderrorsSection renders the worker's reply ALWAYS-HONESTLY, the avc/prev_boot rule (DIA-20260811-10): "we
// read it and it is empty" and "we could not read it" must never be the same output. Only a successful read or
// an ENOENT may say "nothing was logged"; every other outcome says NOT collected and says that this is not
// evidence of no destruction. A nil fetch is a caller that wired no worker (a host or test build).
//
// The lines pass the same scrub as every log. That scrub does not touch a package name -- it redacts quoted
// tokens, key=value secrets, hex, long tokens and 7+ digit runs, and a dotted package name is none of those --
// so the names this section exists to carry survive, while anything secret-shaped is still removed.
// TestUiderrorsSurvivesTheScrub pins both halves. Headers carry no double quote, which the scrub reads as a name.
func uiderrorsSection(fetch func() string, secrets []string) []string {
	if fetch == nil {
		return scrubIssueLines([]string{"uiderrors: NOT collected -- no worker was asked (not a device build) -- this does NOT mean no app data was destroyed"}, secrets)
	}
	const writer = "; its Destroying lines have one writer, the app-data reconcile at a user start -- uninstall, clear-data and user removal do not log here, so an absent line proves nothing about them"
	reply := strings.TrimRight(strings.ReplaceAll(fetch(), "\r\n", "\n"), "\n")
	first, rest, _ := strings.Cut(reply, "\n")
	first = strings.TrimSpace(first)
	var head string
	var lines []string
	switch f := strings.Fields(first); {
	case first == "ABSENT":
		head = "uiderrors: " + uiderrorsPath + " does not exist -- the package manager has logged nothing on this /data" + writer
	case len(f) == 5 && f[0] == "OK":
		for _, ln := range strings.Split(rest, "\n") {
			if strings.TrimSpace(ln) != "" {
				lines = append(lines, ln)
			}
		}
		if len(lines) > maxIssueUiderrorsLines {
			lines = lines[len(lines)-maxIssueUiderrorsLines:] // newest wins: the destroy being reported is recent
		}
		head = fmt.Sprintf("uiderrors: %d line(s) naming user %s were appended to %s since this session signed in (%sB at sign-in, %sB now); %s line(s) about other users or none are withheld%s",
			len(lines), f[4], uiderrorsPath, f[2], f[1], f[3], writer)
	default:
		why := first
		switch {
		case why == "":
			why = "the worker returned nothing"
		case strings.HasPrefix(why, "ERR-LANE"):
			// ⚠ No drop keyword in this text ("passphrase", "password", ...): the scrub would delete the whole
			// header, and the section would go out EMPTY -- the exact silence this function exists to prevent.
			why += " (the worker refused the op: its roamd predates NWP-20261010-06, or a credential reached the read-only lane)"
		case !strings.HasPrefix(why, "ERR"):
			// Not echoed: a reply without the protocol's header is not known to be an error string, and its
			// first line could be file content that never went through this section's own framing.
			why = "the worker's reply was malformed (not ABSENT, not ERR, and not a five-field OK header)"
		}
		head = "uiderrors: NOT collected -- " + why + " -- this does NOT mean no app data was destroyed"
	}
	h := scrubIssueLines([]string{head}, secrets)
	if len(h) == 0 { // a worker error string that tripped a drop keyword: keep the verdict, lose only the reason
		h = []string{"uiderrors: NOT collected -- the reason was withheld by the scrub -- this does NOT mean no app data was destroyed"}
	}
	return append(h, scrubIssueLines(lines, secrets)...)
}

// scrubIssueLines scrubs already-split lines (avcDenials output), same rules as a log file's tail.
func scrubIssueLines(lines, secrets []string) []string {
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		if s, keep := scrubIssueLine(ln, secrets); keep {
			out = append(out, s)
		}
	}
	return out
}

// scrubIssueLog splits raw log bytes, keeps the last maxIssueLogLines, and scrubs each. Returns kept scrubbed
// lines (dropped lines are gone, not blanked, so the tail stays useful).
func scrubIssueLog(raw []byte, secrets []string) []string {
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	if n := len(lines); n > maxIssueLogLines {
		lines = lines[n-maxIssueLogLines:]
	}
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		if strings.TrimSpace(ln) == "" {
			continue
		}
		if s, keep := scrubIssueLine(ln, secrets); keep {
			out = append(out, s)
		}
	}
	return out
}

// issueReport is the device-scrubbed body POSTed to the gateway. The gateway wraps it in an envelope and stores
// it verbatim; nothing here identifies an account (there is none) -- it is operational state + a scrubbed tail.
type issueReport struct {
	Kind      string              `json:"kind"`       // always "issue-report"
	CreatedAt string              `json:"created_at"` // device clock, RFC3339 (coarse; gateway also stamps)
	Note      string              `json:"note,omitempty"`
	Status    map[string]string   `json:"status"`
	Logs      map[string][]string `json:"logs"`
}

// issueLogDir is /data/nowhere in production; overridable for tests/host runs.
func issueLogDir() string {
	if d := os.Getenv("NOWHERE_DIR"); d != "" {
		return d
	}
	return "/data/nowhere"
}

// storeMode reports how this device talks to the store, without revealing endpoints/creds.
func storeMode() string {
	switch {
	case os.Getenv("GATEWAY_URL") != "" && os.Getenv("S3_ACCESS_KEY") == "":
		return "managed"
	case os.Getenv("S3_ACCESS_KEY") != "":
		return "self-hosted"
	default:
		return "local"
	}
}

// issueGatewayURL is where a report goes: GATEWAY_URL when enrolled, else NOWHERE_GATEWAY_DEFAULT
// (NWP-20260819-01). The setup rings deliberately bake only the DEFAULT -- baking GATEWAY_URL would mark
// the device enrolled and skip first-run -- so without the fallback a NEVER-ENROLLED device gets ERR-NOGW,
// and enrolment/provisioning failures are exactly the class the gate reporter exists to carry. Reports
// carry no capability, token or ref, so posting to the default host grants nothing.
func issueGatewayURL() string {
	if gw := strings.TrimRight(os.Getenv("GATEWAY_URL"), "/"); gw != "" {
		return gw
	}
	return strings.TrimRight(os.Getenv("NOWHERE_GATEWAY_DEFAULT"), "/")
}

// gatewayHostHint returns just the host of GATEWAY_URL (no path/query) so support can tell which gateway a
// device targets without the report carrying any capability or ref.
func gatewayHostHint() string {
	u, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil || u.Host == "" {
		return ""
	}
	return u.Host
}

func dataFreeBytes() int64 {
	var st syscall.Statfs_t
	if syscall.Statfs(issueLogDir(), &st) != nil {
		return -1
	}
	return int64(st.Bavail) * int64(st.Bsize)
}

// confRingPath is the ring conf baked into the image; a var so tests can point it at a temp file.
var confRingPath = "/system/etc/nowhere/nowhere.conf"

// confKeyRe is roamd's _nwkeys rule (nowhere_roamd.sh): a line that opens with NAME=.
var confKeyRe = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)=`)

// confKeyNames returns the sorted, de-duplicated key NAMES of the conf at path, comma-joined: "none" for an absent
// file or one with no key, "unreadable" for any other read error. It never returns a value or a comment.
func confKeyNames(path string) string {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "none"
	}
	if err != nil {
		return "unreadable"
	}
	seen := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		if m := confKeyRe.FindStringSubmatch(ln); m != nil {
			seen[m[1]] = true
		}
	}
	if len(seen) == 0 {
		return "none"
	}
	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

// buildIssueReport assembles the scrubbed report. name is the live profile name to redact ("" if none);
// extra is caller-supplied device status (device model, OS build, app version, ...) already gathered by the
// chooser (which has the Android APIs the confined daemon lacks). The agent adds store-mode/gateway/free-space
// and the scrubbed log tails. Enforces the byte ceiling by trimming logs oldest-first.
//
// deviceScopeDomains are the SOURCE domains whose denials a gate report keeps (dn-1105 #1, docs/product-decisions.md
// 2026-10-21). nowhere_otad runs as su, retargeted to endospore_priv on Endospore, so these two cover otad.
var deviceScopeDomains = map[string]bool{
	"update_engine": true, "nowhere": true, "nowhere_chooser": true,
	"endospore_priv": true, "endospore_mediad": true, "su": true,
}

var (
	avcScontextRe = regexp.MustCompile(`\bscontext=u:r:([A-Za-z0-9_]+):`)
	avcAppFieldRe = regexp.MustCompile(` app=\S*`)
)

// deviceScopeDenials keeps the denials whose scontext type is one of the device's own domains, order preserved,
// with every ` app=<token>` field removed. A line with no parseable scontext is dropped; tcontext, comm, name and
// path are never consulted.
func deviceScopeDenials(den []string) []string {
	kept := make([]string, 0, len(den))
	for _, ln := range den {
		m := avcScontextRe.FindStringSubmatch(ln)
		if m == nil || !deviceScopeDomains[m[1]] {
			continue
		}
		kept = append(kept, avcAppFieldRe.ReplaceAllString(ln, ""))
	}
	return kept
}

// deviceScopePrevBoot applies dn-1105 #1 to the previous boot's kernel tail (NWP-20261126-15): logd mirrors audit
// records into the kernel log, so pstore's console carries the denials the avc section filters. A denial line
// (avcDenials' own test) is kept only as deviceScopeDenials keeps it; every other line (the `--- <file> ---`
// headers, init and panic lines) is kept unchanged, order preserved.
func deviceScopePrevBoot(lines []string) []string {
	kept := make([]string, 0, len(lines))
	for _, ln := range lines {
		if strings.Contains(ln, "avc:") && strings.Contains(ln, "denied") {
			kept = append(kept, deviceScopeDenials([]string{ln})...)
			continue
		}
		kept = append(kept, ln)
	}
	return kept
}

// deviceScope (NWP-20260819-01, the gate reporter) restricts collection to DEVICE-level logs only
// (ota.log + provision.log) and is forced on whenever there is no live session. The session logs are
// excluded at the gate for three load-bearing reasons, in order:
//  1. BLIND LOGIN. login.log's verbs are a profile-existence oracle the name-scrub cannot close:
//     "roam-in BLANK" vs "roam-in %q -> user" vs "roam-in NEEDKEY" distinguish an unknown name from a
//     real profile (and NEEDKEY singles out a real 2FA credential pair), and profileTag deliberately
//     renders " p:<4 hex>" OUTSIDE quotes (main.go) so reports can be correlated per profile.
//     The preview path renders the report ON-SCREEN at the gate -- with session logs included, "type a
//     guess, preview, read the verb" would be a no-network oracle for whoever holds the handset.
//  2. LEAST KNOWLEDGE. A gate report otherwise teaches the gateway the device's login-attempt history.
//     We can be compelled to disclose what we hold; the design limits what exists to disclose.
//     The one decided exception is signin_fail.go (Q065): the last failed sign-in's code and age, never a
//     name, tag or uid.
//  3. SIZE. A gate login.log reaches back weeks (nothing wiped it at logoff), and trimIssueReport would
//     evict ota.log -- the one section the gate report exists to carry -- to make room for it.
//
// uiderrors (NWP-20261010-06) fetches the framework's app-data destroy log through the roamd worker; it is
// called only at session scope, and nil there renders an honest "not collected" (see uiderrorsSection).
func buildIssueReport(name string, deviceScope bool, note string, extra map[string]string, uiderrors func() string) issueReport {
	return buildIssueReportWith(name, deviceScope, note, extra, uiderrors, nil)
}

// buildIssueReportWith is buildIssueReport plus the session's anr.seen snapshot (nil: no anr section).
func buildIssueReportWith(name string, deviceScope bool, note string, extra map[string]string, uiderrors func() string, anrSeen map[string]bool) issueReport {
	secrets := []string{}
	if name != "" {
		// Every spelling a log line can carry (NWP-20261008-09): a name holding `"` or `\` is ESCAPED inside %q
		// and qn, so the raw spelling alone never matched it there.
		secrets = append(secrets, nameSpellings(name)...)
	}

	status := map[string]string{
		"store_mode": storeMode(),
	}
	if h := gatewayHostHint(); h != "" {
		status["gateway"] = h
	}
	if fb := dataFreeBytes(); fb >= 0 {
		status["data_free_mb"] = fmt.Sprintf("%d", fb>>20)
	}
	// DIA-20260811-10: say WHICH BOOT this report describes. Without it a reader cannot tell whether the
	// interesting event is in this boot or the last one -- which is the whole difficulty in reading a report
	// filed after a reboot, and it wasted a round on frankel's 12:15:19 restart. boot_id is the kernel's
	// per-boot random value: it changes at every boot and is not derived from anything about the device or the
	// user, so it identifies the BOOT and nothing else. uptime_s says how long ago that boot was.
	for k, v := range withTelClasses(bootMarker(), deviceScope) { // NWP-20260930-04: + telephony classes, gate only
		status[k] = v
	}
	// NWP-20260824-03: the OTA state, in status rather than Logs. A report from a device that could not see a
	// published OTA carried NOTHING about OTA (ticket NW-1c6c3b6d9c7b: its log sections were avc, prev_boot
	// and provision.log), so the one question it was sent to answer was unanswerable from it. status is never
	// trimmed, unlike log sections, and these keys are DEVICE-level -- a published version, a clock age and an
	// error string -- carrying no session or profile fact, so they are safe under the gate reporter's scope.
	// This is also what makes the suspend fix falsifiable on a locked user build, where there is no adb and no
	// logcat: ota_checked_age_s is a WALL-clock age, so a device that has not checked for hours says so.
	// NWP-20261013-40: ota_running is the version the phone runs (/system/etc/nowhere-ota-version), the other
	// half of "why was an update offered or not": ota_latest says what is published, this says what it is
	// compared against. It is a build stamp of the image and nothing else -- no session, profile or user fact --
	// so it is as safe at gate scope as the fingerprint the chooser already sends.
	for k, v := range otaStatusMarker() {
		status[k] = v
	}
	// NWP-20260904-10: why the phone last rebooted, at EVERY scope including the gate. The daemon logs its
	// reboot reason to stderr, which is login.log, which a gate report excludes on purpose (the scope
	// rationale above) -- so ticket NW-b477ab1bce0a ("why phone got rebooted during profile deletion") could
	// not be answered from its own contents, and the fix is NOT to include login.log. The reason lives in
	// its own device-level record instead (lastRebootPath), profile-free by the contract on rebootNow, and is
	// still scrubbed here like every other free-form status value. The other keys are not: none is free-form
	// (integers, booleans, a kernel per-boot random value) and none can carry a secret.
	//
	// Stated cost, not a secret: last_reboot_boot_id is the PREVIOUS boot's boot_id. A report filed in that
	// boot carried it as boot_id, so two tickets from consecutive boots of one handset can be tied together
	// by whoever holds both -- a cross-boot device linkage the per-boot boot_id above does not otherwise
	// allow. It is carried because the report contract for this slice names it; within ONE ticket
	// last_reboot_pending already states what the comparison found, so dropping the raw id would cost nothing
	// but that contract, and is one line here if the trade is ever reversed.
	for k, v := range lastRebootMarker() {
		if k == "last_reboot_reason" {
			v = statusValue(v, secrets)
		}
		status[k] = v
	}
	// NWP-20261117-28: Android's own record of why the phone booted, at EVERY scope including the gate. The
	// last_reboot_* keys above are Nowhere's record only. A reset that no Nowhere path issued leaves them stale:
	// frankel's reboot of 2026-10-28 had ro.boot.bootreason=reset,warm,ecc_ras_error, and the next report named an
	// old OTA. These keys are device level: a bootloader or bootstat string, with no session or profile fact, so
	// they are safe under the gate reporter's scope. They are free-form text from outside Nowhere, so they go
	// through statusValue like last_reboot_reason. "unread" means the read was empty or refused, never "no
	// reboot": the daemon's SELinux domain may not be allowed those property contexts.
	//
	// Stated cost, not a secret: each boot_reason_history line ends in that boot's epoch, so two tickets from one
	// handset share history entries -- a cross-boot device linkage, like last_reboot_boot_id above. statusValue's
	// digit backstop (reIssueDigits) rewrites each 10-digit epoch to <num>, so today the report carries the
	// reasons and their order, not their times; an exemption for that shape would be one line in statusValue.
	for k, v := range bootReasonMarker() {
		v = statusValue(v, secrets)
		if k == "boot_reason_history" {
			v = capBytes(v, bootReasonHistoryCap)
		}
		status[k] = v
	}
	// NWP-20261011-35: how many #83 lost-start recoveries this daemon has made (noteLostStart), at EVERY scope. It
	// is a bare device-level integer, carrying no session or profile fact, so it is safe at the gate. It counts
	// since the DAEMON started, not since boot -- read it against boot_id and uptime_s above.
	status["roam_lost_starts"] = strconv.FormatInt(roamLostStarts.Load(), 10)
	// NWP-20261104-18 (Q152, docs/product-decisions.md): the NAMES of the conf keys this device has set, so a
	// hand-set flag such as NOWHERE_MULTIDEVICE shows in a report, at EVERY scope. roamd prints the same names in
	// roam.log, which a report can lose to trimming and a gate report excludes. These are status keys, never
	// trimmed. Names only, by construction (confKeyNames returns no value and no comment), so the values skip
	// statusValue: there is nothing in them to scrub. It is not telemetry: a report leaves the phone only when
	// the user sends it, and no ops-console column carries it (2026-08-18 no-telemetry stance).
	status["conf_ring_keys"] = confKeyNames(confRingPath)
	status["conf_device_keys"] = confKeyNames(storeConfPath)
	// NWP-20261117-07 (#30): whether the state dir is a tmpfs (yes / no / unknown), at EVERY scope. A device fact and a
	// fixed word, so it skips statusValue. "no" means sign-in, create and resume answer ERR-NOTMPFS (state_tmpfs.go).
	stateTmpfsAnswer, _, _ := stateTmpfs(loginStateDir())
	status["state_tmpfs"] = stateTmpfsAnswer.word()
	// NWP-20261107-14 (Q143, docs/product-decisions.md, dn-1104 #1): the reap ledger's counts per class, at EVERY
	// scope. roamd writes /data/nowhere/reap-ledger and nothing reads it back; on a locked user build nobody can
	// read the file, so this is how the field failure rate is learned. Device facts with no identity: integers and
	// fixed words only (reapLedgerCounts never copies a uid, a time, a census or a name), so they skip statusValue
	// like the conf key names above and are safe at the gate. They cover only the ledger's trimmed tail, never the
	// device's whole history. reap_ledger_userdir is Q037's count of the anchor:timeout and anchor:blind reaps.
	for k, v := range reapLedgerCounts(reapLedgerPath) {
		status[k] = v
	}
	// NWP-20261119-07 (backlog: 0.5.49's grant op runs the Keystore sweep, ...): the last grant op's bundle count and
	// step timings (grant_bundles, grant_keystore_ms, grant_perms_ms, grant_total_ms), SESSION SCOPE ONLY. roam.log's
	// TIMING lines fall outside the report's trimmed tail, and status keys are never trimmed. A bundle count is a fact
	// about the session's profile, so a gate report must not carry it. Digits only (grantTimingStatus copies nothing
	// else), so they skip statusValue.
	if !deviceScope {
		for k, v := range grantTimingStatus(filepath.Join(loginStateDir(), grantTimingFile)) {
			status[k] = v
		}
	}
	for k, v := range extra { // caller status; scrub values defensively (never trust free-form in)
		status[k] = statusValue(v, secrets)
	}

	logs := map[string][]string{}
	dir := issueLogDir()
	// ota.log joined the session set with the gate reporter (NWP-20260819-01): update_engine's rejection
	// reason lands there and nowhere else, and its absence is why #740 was diagnosed by hypothesis -- and
	// why the 2026081820 frankel ERR-APPLY is still an open row instead of a log line.
	bases := []string{"login.log", "roam.log", "mediad.log", "provision.log", "gate.log", "ota.log"}
	if deviceScope {
		// NWP-20260914-02: gate.log joins the DEVICE set. It is the one log built to be here -- a closed
		// verb vocabulary and integer-only values, so it cannot carry a session fact even by accident
		// (gate_log.go states the rule and why it is structural rather than filtered). Without it the
		// gate cannot report on the gate: three tickets filed from it on 2026-09-13 about the gate alarm
		// were all diagnostically empty, and that was by construction, not bad luck.
		bases = []string{"provision.log", "gate.log", "ota.log"} // see the scope rationale on buildIssueReport
	}
	for _, base := range bases {
		raw, err := os.ReadFile(filepath.Join(dir, base))
		if err != nil {
			continue // unreadable (absent / SELinux) -> just omit it
		}
		if s := scrubIssueLog(raw, secrets); len(s) > 0 {
			logs[base] = s
		}
	}
	// DIA-20260806-06: THE CALL avcDenials was added without in DIA-20260806-04. The function was defined and
	// never invoked, so the linker dropped it and no binary ever contained the feature -- while the source
	// looked correct to a reader and to `grep`. It cost two frankel builds and a wrong diagnosis (a "stale
	// agent", which led to DIA-20260806-05) before a string-check of the built binary showed the truth. The
	// lesson is in the check that caught it: grep the BUILT ARTIFACT for a string only the new code can
	// produce, never the source for the symbol you just typed.
	// DIA-20260811-10: UNCONDITIONAL now. The old `if len(den) > 0` is what made a total failure to read
	// indistinguishable from a clean policy -- see avcSection for the evidence (six tickets, zero denial lines,
	// ever). The section always exists and always states which of the two it is.
	den, avcSrc := avcDenials(maxIssueAvcLines)
	if deviceScope {
		// dn-1105 #1 (NWP-20261107-05): the rule is the denial's SOURCE domain, never a substring of the line. A
		// target match kept an untrusted_app denial on a nowhere_ file whose app= field named an app a departed
		// session ran, while roamd's own children (comm="chown", scontext endospore_priv) were dropped.
		den = deviceScopeDenials(den)
	}
	logs["avc"] = avcSection(den, avcSrc, secrets)
	// DIA-20260811-10: the previous boot's kernel tail. logcat is cleared at boot and dmesg is the new boot's
	// ring, so before this a report filed AFTER a reboot carried nothing about the reboot -- on the one device
	// class (locked user builds, no adb) where the report is the only channel. Kept at device scope: it is the
	// bootloop/OTA-reboot evidence, and the kernel console is not a session surface (residual risk accepted
	// and stated: ~~an app name CAN appear in a kernel line~~ *(superseded for denial lines, NWP-20261126-15,
	// below)*; the positional scrubs still run over every line).
	// NWP-20261126-15: logd mirrors audit records into the kernel log, so the console carried the same
	// `scontext=u:r:untrusted_app:... app=<package>` denials the avc section drops.
	// At device scope a denial line here now follows dn-1105 #1 (deviceScopePrevBoot): kept only from the six
	// domains, with no app= field. The residual risk above now covers only NON-denial kernel lines: a comm or
	// a path in a panic trace can still name an app. An inference, not stated by Chester: the decision's rule
	// applies to a denial wherever the report carries it, so the same lines are filtered here; non-denial
	// kernel lines stay, as the decision speaks only of denials. The "nothing collected"/"partial" header is
	// built from pbSrc and is unchanged.
	pb, pbSrc := prevBootTail(maxIssuePrevBootLines)
	if deviceScope {
		pb = deviceScopePrevBoot(pb)
	}
	logs["prev_boot"] = prevBootSection(pb, pbSrc, secrets)
	// DIA-20260811-10: ANR headers -- the process and the reason, which is the part worth having. The full thread
	// dumps are deliberately NOT carried: they are megabytes and would crowd out the logs under the size ceiling.
	// The section carries only traces that were NOT already present when this session began (the anr.seen
	// snapshot), because /data/anr is shared by every session of the boot; no snapshot, no section.
	// NWP-20260819-01 review: EXCLUDED at device scope. `Cmd line: <package>` names the app a DEPARTED
	// session ran (the boot sweep empties /data/anr only at boot, never at a sign-out), it
	// matches no scrub pattern, and secrets is empty at the gate -- so through the gate preview it would
	// disclose past-session app identity with no network. ANRs are also irrelevant to the gate report's
	// remit (OTA/provisioning/boot).
	if !deviceScope {
		if anr, anrSrc := anrHeaders(anrDir, anrSeen, maxIssueAnrLines); len(anr) > 0 || len(anrSrc) > 0 {
			if s := anrSection(anr, anrSrc, secrets); len(s) > 0 {
				logs["anr"] = s
			}
		}
	}

	// NWP-20261010-06: the package manager's record of the per-user app-data dirs its reconcile destroyed. SESSION
	// SCOPE ONLY, and at session scope ONLY THIS SESSION'S LINES: the file outlives every session on this /data, so
	// session scope alone would still have shown a renter the previous renter's apps. The worker filters it to the
	// lines appended since this session signed in that name this session's user (uiderrorsTail says why an offset
	// and not a date). The gate is excluded outright for the anr reason above. A data-loss report comes from inside
	// the session anyway -- a refused seal is exactly what keeps the user from signing out.
	// Preview and Send each build the report, so the worker is asked twice per filed ticket: accepted, it is one
	// read of a file tail on the RO lane, and the two answers can then differ only by lines appended in between.
	if !deviceScope {
		logs["uiderrors"] = uiderrorsSection(uiderrors, secrets)
	}

	rep := issueReport{
		Kind:      "issue-report",
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		Note:      redactIssueSecrets(note, secrets),
		Status:    status,
		Logs:      logs,
	}
	trimIssueReport(&rep)
	return rep
}

// trimIssueReport drops whole logs (largest first, then oldest by our fixed order) until the marshaled report
// fits the device ceiling, so a chatty log can never push a report over the gateway's size limit.
// issueTrimOrder is trimIssueReport's delete list, least-useful first. Package-level (NWP-20260819-01
// review) so the tests assert against THE list, not a copy that can drift -- the first cut of the
// reachability test checked its own duplicate and stayed green when a key was removed from the real one.
// "ota.log" sits AFTER the session logs: on a gate report it is the payload (often the only reason the
// report exists), so every session log must go before it does.
var issueTrimOrder = []string{"provision.log", "mediad.log", "roam.log", "login.log", "gate.log", "ota.log", "crashes", "anr", "uiderrors", "prev_boot", "avc"}

func trimIssueReport(rep *issueReport) {
	// Trim least-useful first. "avc" is LAST deliberately (DIA-20260806-04): a denial names the missing
	// allow line, which no other log can, so it is the one thing worth keeping when a report must shrink.
	// DIA-20260811-10: "anr" and "prev_boot" join the list. A key MISSING from here is never deleted -- the
	// halving step would shrink it but the delete step would skip it -- so any new section must be listed or it
	// silently becomes the most privileged thing in the report. "avc" stays LAST for the reason above;
	// "prev_boot" sits just before it, because on a reboot report it is the only section that can name a cause.
	// NWP-20261010-06: "uiderrors" sits after the logs and anr: it is small (bounded at the source) and on a
	// data-loss report it is the one section that can name what destroyed the data.
	// NWP-20261128-17: "crashes" sits just before "anr": it is the biggest and most app-specific section, and it is
	// already a cut of five records.
	order := issueTrimOrder
	for {
		b, _ := json.Marshal(rep)
		if len(b) <= maxIssueReportBytes {
			return
		}
		trimmed := false
		// First try halving the biggest remaining log; only delete once it is already small.
		var biggest string
		var biggestN int
		for k, v := range rep.Logs {
			if len(v) > biggestN {
				biggestN, biggest = len(v), k
			}
		}
		if biggestN > 40 {
			rep.Logs[biggest] = rep.Logs[biggest][biggestN/2:]
			continue
		}
		for _, k := range order {
			if _, ok := rep.Logs[k]; ok {
				delete(rep.Logs, k)
				trimmed = true
				break
			}
		}
		if !trimmed {
			return // nothing left to trim (note+status only); send as-is
		}
	}
}

// supportNotConfigured is the refusal nowhere-cloud's handleSupport sends with its 503 when the gateway has no
// support intake (GATEWAY_SUPPORT_DIR unset), as gatewayReason yields it. Only this 503 means "switched off".
const supportNotConfigured = "support intake not configured"

// postIssueReport POSTs the report to <gateway>/support and returns the ticket. Reuses the daemon's gateway
// client (30s timeout). On a non-200 it also returns the gateway's refusal text (bounded and sanitised by
// gatewayReason), so the caller can tell a switched-off intake from a full one (dn-1101 #2).
func postIssueReport(gw string, rep issueReport) (ticket string, code int, reason string, err error) {
	var resp struct {
		Ticket string `json:"ticket"`
	}
	code, reason, err = newGatewayClient(gw, gwDefault).postJSONReason("/support", rep, &resp)
	if err != nil {
		return "", code, reason, err
	}
	if code != http.StatusOK {
		return "", code, reason, fmt.Errorf("support intake returned %d", code)
	}
	return resp.Ticket, code, reason, nil
}

// handleReportIssue is the daemon socket verb. Wire form:
//
//	REPORT-ISSUE\n
//	{"note":"...","status":{"device":"Pixel 7a", ...}}\n   (one JSON line; status optional; whole line may be "")
//
// Replies one line: "OK <ticket>" | "ERR-NOGW" (no gateway configured / local mode) | "ERR-DISABLED" (gateway
// support intake off: a 503 whose refusal is exactly "support intake not configured") | "ERR-TOOBIG" (413) |
// "ERR-NET" | "ERR <code>". Every other 503 -- "support intake full", "support intake unavailable", no body, a
// proxy's page -- is "ERR 503": the report was not sent, and the reporters say so ("Couldn't send the report
// (ERR 503).") instead of telling the user support is switched off (dn-1101 #2, docs/product-decisions.md).
// The live profile name (if any) is redacted from everything sent.
func handleReportIssue(conn net.Conn, dest, reqLine string) {
	var req struct {
		Note        string            `json:"note"`
		Status      map[string]string `json:"status"`
		Preview     bool              `json:"preview"`      // build + return the scrubbed report but do NOT send it
		Gate        bool              `json:"gate"`         // the gate reporter: force device scope (see buildIssueReport)
		CrashAccess string            `json:"crash_access"` // NWP-20261128-17: the chooser's DropBox read, ok|denied|error
		Crashes     []string          `json:"crashes"`      // NWP-20261128-17: this session's app crashes, newest first
	}
	if s := strings.TrimSpace(reqLine); s != "" {
		_ = json.Unmarshal([]byte(s), &req) // tolerate a bad/absent body -> empty note+status
	}
	// Redact the live profile name; "" at the gate. NWP-20260904-08: readRoamSessionState, not readRoamSession,
	// on purpose -- a DAMAGED marker that still carries a name must still redact it (a note like "alice won't
	// sync" would otherwise POST unredacted, the exact failure the temp+rename write exists to prevent), and
	// a session that has a name is a live session for scope purposes even when the marker has lost its uid.
	name, _, uid, _ := readRoamSessionState(dest)
	// Device scope is the MORE RESTRICTIVE of what the caller asked and what the session state implies:
	// no .roamsession (markRoamSession only runs inside roam-in's OK branch, so a failed/wedged login never
	// writes one) => device scope regardless of the request; and a gate caller gets device scope even when a
	// warm-switched session is still live, so the gate can never render session logs (the preview oracle).
	deviceScope := req.Gate || name == ""
	rep := buildIssueReportWith(name, deviceScope, req.Note, req.Status, func() string { return fetchUiderrors(dest, name, uid) }, readAnrSeen(dest))
	mergeCrashes(&rep, req.CrashAccess, req.Crashes, name, deviceScope) // NWP-20261128-17 (Q121): session scope only
	trimIssueReport(&rep)                                               // the crash section can be about 20 KiB: trim again
	// After trimIssueReport, so outside the size limit: about 200 bytes against 200 KiB, harmless.
	mergeSigninFail(rep.Status, dest, deviceScope, time.Now()) // NWP-20261106-07 (Q065): after the chooser's status, gate scope only
	mergeSigninSummary(rep.Status, uid, deviceScope)           // NWP-20261122-09: session scope only, this session's uid only
	mergeDaySummary(rep.Status, uid, deviceScope)              // NWP-20261124-12: session scope only, this session's uid only

	if req.Preview {
		// "View what's sent": hand the chooser the EXACT scrubbed bytes to show the user before they consent.
		// No gateway needed; nothing leaves the device.
		b, _ := json.MarshalIndent(rep, "", "  ")
		conn.Write(b)
		fmt.Fprint(conn, "\n")
		return
	}

	gw := issueGatewayURL()
	if gw == "" {
		fmt.Fprint(conn, "ERR-NOGW\n") // local / self-hosted-only device: no support endpoint to reach
		return
	}
	ticket, code, reason, err := postIssueReport(gw, rep)
	switch {
	case err == nil:
		fmt.Fprintf(conn, "OK %s\n", ticket)
	case code == http.StatusServiceUnavailable && reason == supportNotConfigured:
		fmt.Fprint(conn, "ERR-DISABLED\n")
	case code == http.StatusRequestEntityTooLarge:
		fmt.Fprint(conn, "ERR-TOOBIG\n")
	case code == 0:
		fmt.Fprint(conn, "ERR-NET\n") // never reached the gateway (offline)
	default:
		fmt.Fprintf(conn, "ERR %d\n", code)
	}
}
