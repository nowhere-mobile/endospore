package main

import (
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// NWP-20261008-09 (docs/backlog.md, "Profile names survive the on-device log scrub", LOG (1) and (5)).
//
// The data export's two store pointers were the only store keys built from a raw profile name: `export/<name>`
// (handleExport) and `export/<name>#media` (handleExportMedia). A log line that prints such a key prints the name,
// unquoted, and log_scrub could not take it back out: the old export line kept a multi-word name whole, and a
// self-hosted store's retry lines printed `retry PUT ref/export/<name>` on every retry, even one that recovered.
// So the key is redacted where it is PRINTED rather than left to the scrub: in retryStore's `what`, which the store
// calls build raw, and in error text, where a transport error carries the key URL-escaped inside the request URL
// (minio-go v7.2.0 wraps it in a *url.Error and, on a closed connection, repeats the URL unquoted). The export
// re-key decided on 2026-10-08 took the name out of the key altogether (NWP-20261010-02): today's agent writes no
// ref/export/ key, and these rules stay for the CLI's legacy fallback reads and for lines older builds wrote.
var (
	reExportKeyTail = regexp.MustCompile(`(ref/export/).*`)
	reExportKeyEsc  = regexp.MustCompile(`(?i)(ref(?:/|%2f)export(?:/|%2f))[^\s"&?]+`)
	// NWP-20261009-02: a head key, raw or %2F-escaped, and a URL's query string. Since this slice a head key is
	// what the gateway binds a write cap to -- ref/<profileRefV2> IS the bare profile string -- and the query of
	// a presigned URL (X-Amz-Credential, X-Amz-Signature) is a live cap until it expires.
	reRefKey   = regexp.MustCompile(`(?i)(ref(?:/|%2f))[0-9a-f]{64}\b`)
	reURLQuery = regexp.MustCompile(`(https?://[^\s"?#]*)\?[^\s"]*`)
)

// logSafeWhat is retryStore's operation label with an export key's name part removed: "PUT ref/export/<name>",
// and a 64-hex head key reduced to "ref/<ref>" (NWP-20261009-02: capGet's "cap GET ref/<64 hex>"). A blob's
// content hash passes unchanged -- it names bytes, not a profile, and it is the diagnostic.
func logSafeWhat(what string) string {
	return reRefKey.ReplaceAllString(reExportKeyTail.ReplaceAllString(what, "${1}<name>"), "${1}<ref>")
}

// logSafeStoreErr is a store error as a log line may print it. The raw key taken from `what` goes first -- this
// package's own errors print it unescaped, spaces and all (capGet's "cap GET <key> -> ...") -- then every URL's
// query string, then any escaped form of an export key, then any head key (NWP-20261009-02). A net/http
// *url.Error from a cap PUT or GET carries the whole presigned URL, credential and signature included, and the
// gateway's own `gateway /cap?op=write&ref=...` error carries the key query-escaped.
func logSafeStoreErr(what string, err error) string {
	s := err.Error()
	if i := strings.Index(what, "ref/export/"); i >= 0 {
		s = strings.ReplaceAll(s, what[i:], "ref/export/<name>")
	}
	s = reURLQuery.ReplaceAllString(s, "${1}")
	s = reExportKeyEsc.ReplaceAllString(s, "${1}<name>")
	return reRefKey.ReplaceAllString(s, "${1}<ref>")
}

// redactNameIn removes every spelling of a known profile name from text a log line is about to carry: raw,
// %q-escaped, and path- or query-escaped, longest first so a spelling that contains another goes whole; then any
// export key the text still holds. For the export handlers, whose errors can carry the export key in any of those
// forms and which know the name. A very short name is also removed from inside unrelated words -- the safe
// direction, on an error line.
//
// NWP-20261010-02: and any ref/<64 hex>, raw or %2F-escaped. The re-keyed export's keys have that shape and ARE the
// export's authority -- whoever holds one with the profile string can read or mark it -- and a cap or store error
// carries the key it was about (capFlush's "no write cap for ref/...", capGet's "cap GET ref/..."). A proof is never
// in an error: it rides only the lease body. And any URL's query string, as logSafeStoreErr strips it: a presigned
// cap's query is its credential and signature, live until it expires.
func redactNameIn(s, name string) string {
	if name != "" {
		for _, sp := range nameSpellings(name) {
			s = strings.ReplaceAll(s, sp, "<name>")
		}
	}
	s = reURLQuery.ReplaceAllString(s, "${1}")
	return reRefKey.ReplaceAllString(reExportKeyEsc.ReplaceAllString(s, "${1}<name>"), "${1}<ref>")
}

// logSafeErrText is a recovered panic value or an error as a log line may print it (NWP-20261117-26, docs/backlog.md,
// "A sign-in whose chunk fetch fails for good writes the whole presigned store URL, credential and signature
// included, into roam.log"). A store read that fails in transport panics with a storeReadErr around net/http's
// *url.Error, whose text is the whole presigned URL: the query is the cap's credential and signature, the path may
// be a head key. This is the rule connPanicLine and goSafeLine apply, redactNameIn(text, ""): every URL query goes,
// and any head or export key. A text with no URL and no key comes back unchanged. Only the printed text changes:
// a caller that classifies the value (exitStatus, errors.Is) keeps the raw value.
func logSafeErrText(v any) string {
	var s string
	if e, ok := v.(error); ok {
		s = e.Error()
	} else {
		s = fmt.Sprint(v)
	}
	return redactNameIn(s, "")
}

// nameSpellings is every spelling of a profile name a log line can carry: raw; inside %q (logProfile, the daemon);
// inside qn (roamd and mediad, which escape only `\` and `"`); and path- or query-escaped inside a URL. Unique and
// longest first, so a replace pass removes a spelling that contains another whole. The issue reporter's literal
// pass uses it too (buildIssueReport): it used to know only the raw spelling, which never matched an escaped one.
func nameSpellings(name string) []string {
	if name == "" {
		return nil
	}
	q := strconv.Quote(name)
	all := []string{name, q[1 : len(q)-1], strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(name),
		url.PathEscape(name), url.QueryEscape(name)}
	seen := map[string]bool{}
	var out []string
	for _, s := range all {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}
