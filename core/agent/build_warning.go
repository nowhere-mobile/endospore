package main

// build_warning.go -- the signed build-warning object's verifier (NWP-20261109-24, Q098 in docs/product-decisions.md).
//
// A build warning is a small signed object naming the builds a fleet-wide notice applies to. It WARNS and never
// blocks. It is signed under the already-pinned release key (releasePubKey) over a domain prefix + the body, so no new
// key is baked and a release-manifest signature (over the raw manifest bytes) can never pass as a warning, nor a
// warning as a manifest. It carries a sequence number (the caller keeps a floor: a captured old object is a replay)
// and an expiry, and is held to refreshIndex's freshness bound. Any error means no notice.
//
// Everything here is pure: no I/O, no clock, no state. Its caller is acceptBuildWarning (build_warning_fetch.go,
// NWP-20261113-23), which fetches the envelope from ref/ota/build-warning and keeps the durable seq floor; the daemon's
// cache and the gate's notice are the next slices.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	buildWarningMagic       = "nowhere-build-warning 1"
	buildWarningDomain      = "nowhere-build-warning-v1\x00"
	buildWarningMaxBytes    = 16 << 10
	buildWarningMaxVersions = 64
)

// buildWarningKey is the key a warning is checked against: releasePubKey, swapped only by tests.
var buildWarningKey = releasePubKey

// buildWarning is a verified object. Versions are exact OTA version strings (otaVersionRe).
type buildWarning struct {
	Schema   int      `json:"schema"`
	Seq      int64    `json:"seq"`
	Issued   int64    `json:"issued"`
	Expires  int64    `json:"expires"`
	Versions []string `json:"versions"`
}

// buildWarningWire is what the body parses into: pointers, so an absent field is told from a zero one.
type buildWarningWire struct {
	Schema   *int     `json:"schema"`
	Seq      *int64   `json:"seq"`
	Issued   *int64   `json:"issued"`
	Expires  *int64   `json:"expires"`
	Versions []string `json:"versions"`
}

// buildWarningEnvelope is what the store holds: the magic line, the signature line, the body verbatim.
func buildWarningEnvelope(body []byte, sigB64 string) []byte {
	return []byte(buildWarningMagic + "\n" + strings.TrimSpace(sigB64) + "\n" + string(body))
}

// openBuildWarningEnvelope splits an envelope into the signature and the body bytes, verbatim.
func openBuildWarningEnvelope(b []byte) (sigB64 string, body []byte, err error) {
	rest, ok := strings.CutPrefix(string(b), buildWarningMagic+"\n")
	if !ok {
		return "", nil, errors.New("not a build-warning envelope")
	}
	sig, bod, ok := strings.Cut(rest, "\n")
	if !ok {
		return "", nil, errors.New("truncated build-warning envelope")
	}
	return sig, []byte(bod), nil
}

// buildWarningField returns a required time or sequence field; absent or zero is refused, never defaulted
// (docs/fleet-lock-design.md §3.3).
func buildWarningField(field string, p *int64) (int64, error) {
	if p == nil || *p <= 0 {
		return 0, fmt.Errorf("build warning: %s absent or zero", field)
	}
	return *p, nil
}

// verifyBuildWarning opens env, checks the signature BEFORE reading any field, and returns the object only when every
// rule holds. floor is the highest seq the caller has accepted; seq must be above it (the caller keeps the floor).
func verifyBuildWarning(pubB64 string, env []byte, now, floor int64) (*buildWarning, error) {
	sig, body, err := openBuildWarningEnvelope(env)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 || len(body) > buildWarningMaxBytes {
		return nil, fmt.Errorf("build warning: body is %d bytes", len(body))
	}
	msg := make([]byte, 0, len(buildWarningDomain)+len(body))
	msg = append(append(msg, buildWarningDomain...), body...)
	if !verifyReleaseSig(pubB64, msg, sig) {
		return nil, errors.New("build warning: the signature does not verify")
	}
	var w buildWarningWire
	if err := json.Unmarshal(body, &w); err != nil {
		return nil, fmt.Errorf("build warning: %w", err)
	}
	if w.Schema == nil || *w.Schema != 1 {
		return nil, errors.New("build warning: unsupported schema")
	}
	seq, err := buildWarningField("seq", w.Seq)
	if err != nil {
		return nil, err
	}
	issued, err := buildWarningField("issued", w.Issued)
	if err != nil {
		return nil, err
	}
	expires, err := buildWarningField("expires", w.Expires)
	if err != nil {
		return nil, err
	}
	if seq <= floor {
		return nil, fmt.Errorf("build warning: seq %d is not above the floor %d (replay)", seq, floor)
	}
	if issued > now+86400 {
		return nil, errors.New("build warning: issued in the future")
	}
	if issued < now-maxIndexStaleness {
		return nil, errors.New("build warning: too stale")
	}
	if expires <= now {
		return nil, errors.New("build warning: expired")
	}
	if expires <= issued {
		return nil, errors.New("build warning: expires before it was issued")
	}
	if len(w.Versions) == 0 || len(w.Versions) > buildWarningMaxVersions {
		return nil, fmt.Errorf("build warning: %d versions", len(w.Versions))
	}
	seen := map[string]bool{}
	for _, v := range w.Versions {
		if !otaVersionRe.MatchString(v) {
			return nil, errors.New("build warning: a version is malformed")
		}
		if seen[v] {
			return nil, errors.New("build warning: a version is listed twice")
		}
		seen[v] = true
	}
	return &buildWarning{Schema: 1, Seq: seq, Issued: issued, Expires: expires, Versions: append([]string(nil), w.Versions...)}, nil
}

// affects reports whether version is one of the named builds, exactly. A nil warning affects nothing.
func (b *buildWarning) affects(version string) bool {
	if b == nil {
		return false
	}
	for _, v := range b.Versions {
		if v == version {
			return true
		}
	}
	return false
}
