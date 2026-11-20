package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"regexp"
	"strings"
)

// bootsweepSiblingsKeys are the seven fields of roamd's bootsweep fix 18 line (NWP-20261129-44), in the order the
// report prints them.
var bootsweepSiblingsKeys = []string{"softap", "scorecard", "health", "suggest", "netstats", "netpolicy", "wifidir"}

// bootsweepSiblingsPrefix starts the one roam.log line this reader looks at.
const bootsweepSiblingsPrefix = "[roamd] bootsweep siblings: "

// bootsweepSiblingsTailBytes bounds what a report reads of roam.log. log_scrub keeps a 1 MiB tail, but a reader must
// not trust the writer's bound.
const bootsweepSiblingsTailBytes = 2 << 20

// bootsweepSiblingsValueRe is the value grammar of _sb_state (test-bootsweep-siblings.sh): absent, unreachable, or a
// context (or ? when ls gives none) and /w0 or /w1. A label with an MLS category list does not match.
var bootsweepSiblingsValueRe = regexp.MustCompile(`^(absent|unreachable|(\?|u:object_r:[a-z0-9_]+:s0)/w[01])$`)

// bootsweepSiblingsStatus renders the boot sweep's siblings line as the issue-report status key bootsweep_siblings
// (NWP-20261204-20). Backlog row "Four sibling Wi-Fi/network stores nothing sweeps": the line is its HW3 evidence, and
// its LIMIT was that a gate report excludes roam.log and a session report keeps only each log's last 300 lines, so a
// report could miss the line. A status key is never trimmed and is carried at every scope.
//
//	"softap=<v> scorecard=<v> health=<v> suggest=<v> netstats=<v> netpolicy=<v> wifidir=<v>"
//	                     <v> is a value bootsweepSiblingsValueRe accepts, OTHER for any other value (a category list,
//	                     a path, a word), missing when the line has no such key
//	"none"               the tail holds no siblings line
//	"none (no roam.log)" the file does not exist
//	"unreadable"         any other error (no path, no error text)
//
// The value set is fixed (the seven keys, fixed words and labels without categories), so the key skips statusValue:
// unknown keys and the date words are never copied. It is the LATEST line in the last bootsweepSiblingsTailBytes of
// roam.log; log_scrub keeps a 1 MiB tail, so a long session can push the line out, and then the key reads none.
func bootsweepSiblingsStatus(path string) string {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "none (no roam.log)"
	}
	if err != nil {
		return "unreadable"
	}
	defer f.Close()
	b, err := bootsweepSiblingsTail(f)
	if err != nil {
		return "unreadable"
	}
	last := ""
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSuffix(ln, "\r")
		if strings.HasPrefix(ln, bootsweepSiblingsPrefix) {
			last = ln
		}
	}
	if last == "" {
		return "none"
	}
	_, body, _ := strings.Cut(last, "siblings: ")
	vals := map[string]string{}
	for _, fl := range strings.Fields(body) {
		k, v, ok := strings.Cut(fl, "=")
		if !ok {
			continue
		}
		if _, seen := vals[k]; !seen {
			vals[k] = v
		}
	}
	out := make([]string, 0, len(bootsweepSiblingsKeys))
	for _, k := range bootsweepSiblingsKeys {
		v, ok := vals[k]
		switch {
		case !ok:
			v = "missing"
		case !bootsweepSiblingsValueRe.MatchString(v):
			v = "OTHER"
		}
		out = append(out, k+"="+v)
	}
	return strings.Join(out, " ")
}

// bootsweepSiblingsTail reads at most the last bootsweepSiblingsTailBytes; when it starts mid-file the first (partial)
// line goes.
func bootsweepSiblingsTail(f *os.File) ([]byte, error) {
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	cut := false
	if st.Mode().IsRegular() && st.Size() > bootsweepSiblingsTailBytes {
		if _, err := f.Seek(st.Size()-bootsweepSiblingsTailBytes, io.SeekStart); err != nil {
			return nil, err
		}
		cut = true
	}
	b, err := io.ReadAll(io.LimitReader(f, bootsweepSiblingsTailBytes))
	if err != nil {
		return nil, err
	}
	if cut {
		i := strings.IndexByte(string(b), '\n')
		if i < 0 {
			return nil, nil
		}
		b = b[i+1:]
	}
	return b, nil
}
