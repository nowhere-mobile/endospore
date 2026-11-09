package main

// index_key.go -- the index-key rollover/revocation object's verifier (NWP-20261124-25, decision #8 of 2026-11-02 in
// docs/product-decisions.md, "twenty-four answers to the open-decisions list ...").
//
// indexPubKey (index.go) checks an index that an automated job re-publishes every few hours from an ONLINE key, so a
// leak of that key signs a poisoned trimmed index (stale URLs, a reverted removal) that every phone accepts until an
// OTA reaches it. This object moves a phone to a new index key, or makes it refuse a revoked one, without an OTA. It is
// signed under the already-pinned OFFLINE release key (releasePubKey) over its own domain prefix + the body, as Q098's
// build warning is (build_warning.go): a leaked index key cannot sign its own replacement, and neither a release
// manifest (signed over the raw bytes) nor a build warning (its own domain) can pass as one, nor it as them. It carries
// a sequence number; the caller keeps the floor, so a captured old object is a replay. Any error means no object.
//
// Every key in the body is STANDARD base64 of a 32-byte ed25519 public key: the spelling indexPubKey uses and
// verifyEd25519 decodes, so a selected key checks an index unchanged. Keys are compared by their DECODED bytes, never as
// strings: the decoder trims spaces and ignores the spare bits of the last character, so two spellings can name one key.
//
// Everything here is pure: no I/O, no clock, no state. index_key_fetch.go calls it (activeIndexKey says what is left).

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	indexKeyMagic      = "nowhere-index-key 1"
	indexKeyDomain     = "nowhere-index-key-v1\x00"
	indexKeyMaxBytes   = 4 << 10
	indexKeyMaxRevoked = 16
)

// indexKeyObjectKey is the key an index-key object is checked against: releasePubKey, swapped only by tests.
var indexKeyObjectKey = releasePubKey

// indexKeyObject is a verified object. Key ("" when the object only revokes) and Revoked hold canonical standard
// base64, re-encoded from the decoded bytes.
type indexKeyObject struct {
	Schema  int
	Seq     int64
	Issued  int64
	Key     string
	Revoked []string
}

// indexKeyWire is what the body parses into: pointers, so an absent field is told from a zero one.
type indexKeyWire struct {
	Schema  *int     `json:"schema"`
	Seq     *int64   `json:"seq"`
	Issued  *int64   `json:"issued"`
	Key     *string  `json:"key"`
	Revoked []string `json:"revoked"`
}

// indexKeyEnvelope is what the store holds: the magic line, the signature line, the body verbatim.
func indexKeyEnvelope(body []byte, sigB64 string) []byte {
	return []byte(indexKeyMagic + "\n" + strings.TrimSpace(sigB64) + "\n" + string(body))
}

// openIndexKeyEnvelope splits an envelope into the signature and the body bytes, verbatim.
func openIndexKeyEnvelope(b []byte) (sigB64 string, body []byte, err error) {
	rest, ok := strings.CutPrefix(string(b), indexKeyMagic+"\n")
	if !ok {
		return "", nil, errors.New("not an index-key envelope")
	}
	sig, bod, ok := strings.Cut(rest, "\n")
	if !ok {
		return "", nil, errors.New("truncated index-key envelope")
	}
	return sig, []byte(bod), nil
}

// indexKeyField returns a required time or sequence field; absent or zero is refused, never defaulted.
func indexKeyField(field string, p *int64) (int64, error) {
	if p == nil || *p <= 0 {
		return 0, fmt.Errorf("index key object: %s absent or zero", field)
	}
	return *p, nil
}

// indexKeyBytes decodes a key as verifyEd25519 does (TrimSpace, then StdEncoding) and requires 32 bytes.
func indexKeyBytes(s string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return nil, errors.New("index key object: a key is not standard base64")
	}
	if len(b) != 32 {
		return nil, fmt.Errorf("index key object: a key is %d bytes, not 32", len(b))
	}
	return b, nil
}

// indexKeyIn reports whether key is in list by DECODED bytes, never by string. An undecodable key matches nothing.
func indexKeyIn(key string, list []string) bool {
	k, err := indexKeyBytes(key)
	if err != nil {
		return false
	}
	for _, r := range list {
		if rb, err := indexKeyBytes(r); err == nil && bytes.Equal(rb, k) {
			return true
		}
	}
	return false
}

// verifyIndexKeyObject opens env, checks the signature BEFORE reading any field, and returns the object only when every
// rule holds. floor is the highest seq the caller has accepted; seq must be above it (the caller keeps the floor).
func verifyIndexKeyObject(pubB64 string, env []byte, now, floor int64) (*indexKeyObject, error) {
	sig, body, err := openIndexKeyEnvelope(env)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 || len(body) > indexKeyMaxBytes {
		return nil, fmt.Errorf("index key object: body is %d bytes", len(body))
	}
	msg := make([]byte, 0, len(indexKeyDomain)+len(body))
	msg = append(append(msg, indexKeyDomain...), body...)
	if !verifyReleaseSig(pubB64, msg, sig) {
		return nil, errors.New("index key object: the signature does not verify")
	}
	var w indexKeyWire
	if err := json.Unmarshal(body, &w); err != nil {
		return nil, fmt.Errorf("index key object: %w", err)
	}
	if w.Schema == nil || *w.Schema != 1 {
		return nil, errors.New("index key object: unsupported schema")
	}
	seq, err := indexKeyField("seq", w.Seq)
	if err != nil {
		return nil, err
	}
	issued, err := indexKeyField("issued", w.Issued)
	if err != nil {
		return nil, err
	}
	if seq <= floor {
		return nil, fmt.Errorf("index key object: seq %d is not above the floor %d (replay)", seq, floor)
	}
	if issued > now+86400 {
		return nil, errors.New("index key object: issued in the future")
	}
	// No expiry and no staleness bound, by design: a rollover stands until an object with a higher seq replaces it. If
	// a rollover expired, every phone would go back to the baked key, which is the leaked key the rollover moved it off.
	// The caller's seq floor is the replay guard.
	if w.Key == nil && len(w.Revoked) == 0 {
		return nil, errors.New("index key object: it names no key and revokes none")
	}
	if len(w.Revoked) > indexKeyMaxRevoked {
		return nil, fmt.Errorf("index key object: %d revoked keys, at most %d", len(w.Revoked), indexKeyMaxRevoked)
	}
	var revoked []string
	seen := map[string]bool{}
	for _, r := range w.Revoked {
		rb, err := indexKeyBytes(r)
		if err != nil {
			return nil, err
		}
		if seen[string(rb)] {
			return nil, errors.New("index key object: a revoked key is listed twice")
		}
		seen[string(rb)] = true
		revoked = append(revoked, base64.StdEncoding.EncodeToString(rb))
	}
	key := ""
	if w.Key != nil {
		kb, err := indexKeyBytes(*w.Key)
		if err != nil {
			return nil, err
		}
		key = base64.StdEncoding.EncodeToString(kb)
	}
	if w.Key != nil && indexKeyIn(*w.Key, w.Revoked) {
		return nil, errors.New("index key object: the new key is itself revoked")
	}
	return &indexKeyObject{Schema: 1, Seq: seq, Issued: issued, Key: key, Revoked: revoked}, nil
}

// activeIndexKey returns the key the /data index refresh is checked against, given the baked indexPubKey and the
// verified object (nil when the phone holds none): a rollover's key; else the baked key, unless the object revokes it,
// in which case "" -- and "" means "no /data refresh is accepted", NEVER "unsigned".
//
// NWP-20261126-14 built the fetch (as Q098's build_warning_fetch.go followed build_warning.go): index_key_fetch.go's
// fetchIndexKey reads ref/ota/index-key, acceptIndexKey keeps the accepted envelope and its durable seq floor
// (/data/nowhere/index-key, index-key-seq), and currentIndexKey selects the refresh key or none.
//
// NWP-20261129-18 built the calls: refreshOtaCache calls fetchIndexKey after each completed OTA check, and index.go
// calls currentIndexKey. The selected key replaces indexPubKey ONLY for the /data refresh (loadIndexBytesWith's /data branch)
// and refreshIndex's checks. The baked /system copy is signed by the baked key and rides verified boot, so it keeps
// verifyIndexSig's baked key. The `indexPubKey == ""` branches trust the baked copy unsigned, so they keep reading the
// BAKED key: an "" from here must never reach them.
//
// NWP-20261129-24 built the operator's put command (index_key_put.go), which publishes the object only above the
// published seq.
func activeIndexKey(baked string, obj *indexKeyObject) string {
	if obj == nil {
		return baked
	}
	if obj.Key != "" {
		return obj.Key
	}
	// The baked key is revoked and no replacement is named: accept no /data refresh.
	if indexKeyIn(baked, obj.Revoked) {
		return ""
	}
	return baked
}
