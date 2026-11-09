package main

// index_key_put.go -- the operator's publish verb for the index-key object (NWP-20261129-24, decision #8 of 2026-11-02
// in docs/product-decisions.md, "twenty-four answers to the open-decisions list ...", docs/release-runbook.md §5b).
//
// This is the build host's half: main's index-key-check / index-key-put run it, and it never runs on a phone. It checks
// a signed envelope (FILE.env, signed offline under the release key by nowhere-cloud's cmd/release) with the very code
// and key a phone uses, then publishes it at ref/ota/index-key. A phone holds a durable floor at the highest seq it
// accepted and refuses anything at or below it as a replay (acceptIndexKey), so a publish whose seq is not strictly
// above the published one would be refused by every phone that saw the earlier one, silently. That publish is refused
// here, before any write; so is one over a published object that does not verify, and one on a store error. Only public
// keys exist here.

import (
	"fmt"
	"io"
	"os"
)

// indexKeyCheckFile reads the envelope at path (refused over indexKeyEnvMax bytes, without being held whole) and
// verifies it as a phone would at now, with no floor. It returns the object and the envelope's bytes.
func indexKeyCheckFile(path string, now int64) (*indexKeyObject, []byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	env, err := io.ReadAll(io.LimitReader(f, indexKeyEnvMax+1))
	if err != nil {
		return nil, nil, err
	}
	if len(env) > indexKeyEnvMax {
		return nil, nil, fmt.Errorf("the file is over the %d-byte cap", indexKeyEnvMax)
	}
	obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, now, 0)
	if err != nil {
		return nil, nil, err
	}
	return obj, env, nil
}

// indexKeyPut checks the envelope at path, then publishes it at ref/ota/index-key on store, only when its seq is
// strictly above the published object's. It returns the object and the blob's hash. Every refusal comes before either
// write; the blob is posted before the ref names it (content-addressed, so inert until then).
func indexKeyPut(store, path string, now int64) (*indexKeyObject, string, error) {
	obj, env, err := indexKeyCheckFile(path, now)
	if err != nil {
		return nil, "", err
	}
	// Fail closed: a publish that cannot see the published seq could go at or below it.
	pub, err := fetchIndexKeyEnvelope(store)
	if err != nil {
		return nil, "", fmt.Errorf("the published object could not be read; nothing written: %w", err)
	}
	if pub != nil {
		// One verify is enough. This object has no expiry, so it cannot fail only by age, and the build warning's second
		// verify at its own issue time has no case to cover here.
		p, perr := verifyIndexKeyObject(indexKeyObjectKey, pub, now, 0)
		if perr != nil {
			return nil, "", fmt.Errorf("the published object does not verify (%v): another key wrote it, or it is damaged; nothing written", perr)
		}
		if obj.Seq <= p.Seq {
			return nil, "", fmt.Errorf("seq %d is not above the published seq %d; phones that saw seq %d refuse it as a replay; nothing written", obj.Seq, p.Seq, p.Seq)
		}
	}
	h := postBlob(store, env)
	putRef(store, indexKeyRefName, h)
	return obj, h, nil
}
