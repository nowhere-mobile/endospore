package main

// build_warning_put.go -- the operator's publish verb for the build warning (NWP-20261113-30, Q098 in
// docs/product-decisions.md, docs/release-runbook.md §5).
//
// This is the build host's half: main's build-warning-check / build-warning-put run it, and it never runs on a phone.
// It checks a signed envelope (FILE.env, written offline by nowhere-cloud's `cmd/release sign-warning`) with the very
// code and key a phone uses, then publishes it at ref/ota/build-warning. A phone holds a durable floor at the highest
// seq it accepted and refuses anything at or below it as a replay (acceptBuildWarning), so a publish whose seq is not
// strictly above the published one would be refused by every phone that saw the earlier one, silently. That publish is
// refused here, before any write; so is one over a published object that does not verify, and one on a store error.

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// buildWarningCheckFile reads the envelope at path (refused over buildWarningEnvMax bytes, without being held whole)
// and verifies it as a phone would at now, with no floor. It returns the warning and the envelope's bytes.
func buildWarningCheckFile(path string, now int64) (*buildWarning, []byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	env, err := io.ReadAll(io.LimitReader(f, buildWarningEnvMax+1))
	if err != nil {
		return nil, nil, err
	}
	if len(env) > buildWarningEnvMax {
		return nil, nil, fmt.Errorf("the file is over the %d-byte cap", buildWarningEnvMax)
	}
	w, err := verifyBuildWarning(buildWarningKey, env, now, 0)
	if err != nil {
		return nil, nil, err
	}
	return w, env, nil
}

// buildWarningPut checks the envelope at path, then publishes it at ref/ota/build-warning on store, only when its seq
// is strictly above the published object's. It returns the warning and the blob's hash. Every refusal comes before
// either write; the blob is posted before the ref names it (content-addressed, so inert until then).
func buildWarningPut(store, path string, now int64) (*buildWarning, string, error) {
	w, env, err := buildWarningCheckFile(path, now)
	if err != nil {
		return nil, "", err
	}
	// Fail closed: a publish that cannot see the published seq could go at or below it.
	pub, err := fetchBuildWarningEnvelope(store)
	if err != nil {
		return nil, "", fmt.Errorf("the published warning could not be read; nothing written: %w", err)
	}
	if pub != nil {
		p, perr := verifyBuildWarning(buildWarningKey, pub, now, 0)
		if perr != nil {
			// The published object may only have expired or gone stale, and phones that saw it still hold its seq
			// as their floor. Verify it again with its own Issued as the clock. That Issued is unverified, but it is
			// used ONLY as the clock: verifyBuildWarning still checks the signature before it reads any field, and
			// then the schema, the seq, expires > issued and the versions, so a forged or damaged blob still fails
			// and a seq is never read from an object that does not verify.
			var wire buildWarningWire
			if _, body, oerr := openBuildWarningEnvelope(pub); oerr == nil && json.Unmarshal(body, &wire) == nil && wire.Issued != nil {
				p, perr = verifyBuildWarning(buildWarningKey, pub, *wire.Issued, 0)
			}
		}
		if perr != nil {
			return nil, "", fmt.Errorf("the published warning verifies neither now nor at its own issue time (%v): another key wrote it, or it is damaged; nothing written", perr)
		}
		if w.Seq <= p.Seq {
			return nil, "", fmt.Errorf("seq %d is not above the published seq %d; phones that saw seq %d refuse it as a replay; nothing written", w.Seq, p.Seq, p.Seq)
		}
	}
	h := postBlob(store, env)
	putRef(store, buildWarningRefName, h)
	return w, h, nil
}
