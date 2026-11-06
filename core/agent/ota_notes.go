package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// NWP-20261006-12 -- the OTA summary: what is in a release, from the version on the phone to the one it is offered.
//
// Chester, 2026-09-21: "can we have an ota summary (whats in the release) with the release? ... a clickable link on
// the version number with a popup with few key points"; 2026-10-04: "it should include all changes from whats on the
// device->the latest version"; 2026-10-06: I draft the points from the merged PRs and he edits them, and they stay to
// plain features and fixes, so a release's notes never need counsel review under docs/privacy-claims.md.
//
// FORMAT -- one plain-text file per released version, committed as core/vendor-common/etc/ota-notes/<version>:
//
//	version 0.5.43
//	previous 0.5.42
//	- A point, one line.
//	- Another.
//
// `previous` names the version released before it, so a phone can walk back from the version it is OFFERED to the
// one it RUNS: the store can only fetch a name it already knows, it cannot list. 1..otaNotesMaxPoints points.
//
// PINNING. The OTA marker is pinned to the exact image it describes, so the notes are too:
//   - the RUNNING version's notes are baked into the image (/system/etc/nowhere-ota-notes, staged from the file for
//     the image's own stamp), so they cannot drift and are readable offline;
//   - a PUBLISHED version's notes sit beside the marker at ota/<dev>/notes-<version> (a ref to a content-addressed
//     blob), written by e4-ota-publish.sh BEFORE the marker, so a phone that sees the marker can fetch them.
//     Promotion needs nothing: notes are keyed by version, not by ring.

const (
	otaNotesMaxPoints = 6
	otaNotesMaxPoint  = 160  // characters per point
	otaNotesMaxBytes  = 2048 // the whole file
	otaNotesMaxWalk   = 20   // versions a phone walks back before it says "and earlier changes"
	otaNotesBaked     = "/system/etc/nowhere-ota-notes"
)

type otaNotes struct {
	Version  string
	Previous string
	Points   []string
}

var otaVersionRe = regexp.MustCompile(`^[0-9]+(\.[0-9]+){1,3}$`)

// otaNotesClaimWords are words that make a privacy or security claim. Notes stay to features and fixes (Chester,
// 2026-10-06), because every privacy claim needs counsel review (docs/privacy-claims.md). A point that needs one of
// these words is the wrong kind of point for release notes; say what changed, not what it protects.
var otaNotesClaimWords = regexp.MustCompile(`(?i)\b(privacy|private|privately|anonymous|anonymity|anonymously|secure|securely|security|encrypt\w*|decrypt\w*|tracking|tracker\w*|untrack\w*|surveil\w*|safe|safer|safely|safety|protect\w*|confidential\w*|zero[- ]knowledge|no[- ]logs?|can'?t see|cannot see|never see)\b`)

// parseOtaNotes reads and validates one notes file. Every rule is a refusal, so a bad file fails at commit (the CI
// test over every file in the tree) and again at publish, never on a phone.
func parseOtaNotes(text string) (*otaNotes, error) {
	if len(text) > otaNotesMaxBytes {
		return nil, fmt.Errorf("notes are %d bytes, over the %d cap", len(text), otaNotesMaxBytes)
	}
	if !utf8.ValidString(text) {
		return nil, errors.New("notes are not UTF-8")
	}
	lines := strings.Split(strings.TrimRight(strings.ReplaceAll(text, "\r\n", "\n"), "\n"), "\n")
	if len(lines) < 3 {
		return nil, errors.New("want a version line, a previous line and at least one point")
	}
	n := &otaNotes{}
	if v, ok := strings.CutPrefix(lines[0], "version "); !ok || !otaVersionRe.MatchString(v) {
		return nil, fmt.Errorf("line 1 must be `version <x.y.z>`, got %q", lines[0])
	} else {
		n.Version = v
	}
	if p, ok := strings.CutPrefix(lines[1], "previous "); !ok || !otaVersionRe.MatchString(p) {
		return nil, fmt.Errorf("line 2 must be `previous <x.y.z>`, got %q", lines[1])
	} else if !semverLess(p, n.Version) {
		return nil, fmt.Errorf("previous %s is not older than version %s", p, n.Version)
	} else {
		n.Previous = p
	}
	for i, l := range lines[2:] {
		pt, ok := strings.CutPrefix(l, "- ")
		pt = strings.TrimSpace(pt)
		if !ok || pt == "" {
			return nil, fmt.Errorf("line %d must be a point `- <text>`, got %q", i+3, l)
		}
		if utf8.RuneCountInString(pt) > otaNotesMaxPoint {
			return nil, fmt.Errorf("point %d is %d characters, over %d", i+1, utf8.RuneCountInString(pt), otaNotesMaxPoint)
		}
		for _, r := range pt {
			if unicode.IsControl(r) {
				return nil, fmt.Errorf("point %d has a control character", i+1)
			}
		}
		if w := otaNotesClaimWords.FindString(pt); w != "" {
			return nil, fmt.Errorf("point %d says %q: notes are features and fixes, not privacy or security claims (docs/privacy-claims.md)", i+1, w)
		}
		n.Points = append(n.Points, pt)
	}
	if len(n.Points) > otaNotesMaxPoints {
		return nil, fmt.Errorf("%d points, over %d", len(n.Points), otaNotesMaxPoints)
	}
	return n, nil
}

// otaDev is the device whose fleet this image belongs to, from the baked os-ref (the same source otaVersionRef uses).
func otaDev() string {
	if b, err := os.ReadFile("/system/etc/nowhere/os-ref"); err == nil {
		if dev := strings.TrimPrefix(strings.TrimSpace(string(b)), "os-"); dev != "" {
			return dev
		}
	}
	return "fp3"
}

func otaNotesRef(dev, version string) string { return "ota/" + dev + "/notes-" + version }

// fetchOtaNotes reads a published version's notes: the ref, then the blob it names, whose content must hash to that
// name and must describe exactly that version. (nil, nil) means none are published for it.
func fetchOtaNotes(base, dev, version string) (n *otaNotes, err error) {
	defer func() {
		if r := recover(); r != nil {
			n, err = nil, fmt.Errorf("store: %v", r)
		}
	}()
	h := getRef(base, otaNotesRef(dev, version))
	if h == "" {
		return nil, nil
	}
	b, ok := getBlobSoft(base, h)
	if !ok {
		return nil, fmt.Errorf("notes blob %.12s missing", h)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != h {
		return nil, fmt.Errorf("notes blob %.12s does not match its name", h)
	}
	n, err = parseOtaNotes(string(b))
	if err != nil {
		return nil, err
	}
	if n.Version != version {
		return nil, fmt.Errorf("notes at %s describe %s", version, n.Version)
	}
	return n, nil
}

// walkOtaNotes collects the notes from `offered` back to (not including) `running`, newest first. more is true when
// the walk stopped while versions newer than `running` were still undescribed: a version with no notes published
// (one released before this feature), a fetch that failed, or the walk cap.
func walkOtaNotes(fetch func(string) (*otaNotes, error), offered, running string) (chain []*otaNotes, more bool) {
	v := offered
	for v != "" && semverLess(running, v) {
		if len(chain) >= otaNotesMaxWalk {
			return chain, true
		}
		n, err := fetch(v)
		if err != nil || n == nil {
			return chain, true
		}
		chain = append(chain, n)
		v = n.Previous
	}
	return chain, false
}

// --- the gate's cache: the walk does network I/O, and the daemon serves requests one at a time, so OTA-NOTES must
// answer from memory. Refreshed by the OTA refresh, in its own goroutine, whenever the offered version changes.
var (
	otaNotesMu      sync.Mutex
	otaNotesOffered string
	otaNotesChain   []*otaNotes
	otaNotesMore    bool
	otaNotesAt      time.Time
)

const otaNotesRetry = 15 * time.Minute

// refreshOtaNotes walks the chain for `offered` if the cache does not already hold it (or an incomplete walk is old
// enough to retry). Called from refreshOtaCache, off the request path.
func refreshOtaNotes(base, offered, running string) {
	otaNotesMu.Lock()
	fresh := otaNotesOffered == offered && (!otaNotesMore || time.Since(otaNotesAt) < otaNotesRetry)
	otaNotesMu.Unlock()
	if offered == "" || fresh {
		return
	}
	dev := otaDev()
	chain, more := walkOtaNotes(func(v string) (*otaNotes, error) { return fetchOtaNotes(base, dev, v) }, offered, running)
	otaNotesMu.Lock()
	otaNotesOffered, otaNotesChain, otaNotesMore, otaNotesAt = offered, chain, more, time.Now().Round(0)
	otaNotesMu.Unlock()
}

// bakedOtaNotes reads the running image's own notes; nil when there are none or they describe another version.
func bakedOtaNotes(path, running string) *otaNotes {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	n, err := parseOtaNotes(string(b))
	if err != nil || n.Version != running {
		return nil
	}
	return n
}

// writeOtaNotesReply renders OTA-NOTES:
//
//	RUNNING <version>        the version this image is
//	NOTE <point>             its own notes, if it has any
//	OFFERED <version>        for each version from the offered one back towards the running one, newest first
//	NOTE <point>
//	MORE                     there are earlier changes these notes do not describe
//	END
//
// OFFERED blocks appear only while an update is available and its walk has run.
func writeOtaNotesReply(w *strings.Builder, running string, own *otaNotes, avail bool, offered string) {
	fmt.Fprintf(w, "RUNNING %s\n", running)
	if own != nil {
		for _, p := range own.Points {
			fmt.Fprintf(w, "NOTE %s\n", p)
		}
	}
	if avail {
		otaNotesMu.Lock()
		if otaNotesOffered == offered {
			for _, n := range otaNotesChain {
				fmt.Fprintf(w, "OFFERED %s\n", n.Version)
				for _, p := range n.Points {
					fmt.Fprintf(w, "NOTE %s\n", p)
				}
			}
			if otaNotesMore {
				w.WriteString("MORE\n")
			}
		}
		otaNotesMu.Unlock()
	}
	w.WriteString("END\n")
}
