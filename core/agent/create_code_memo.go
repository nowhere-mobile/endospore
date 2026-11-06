package main

import (
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"time"
)

// NWP-20261101-03 (Q048, docs/product-decisions.md 2026-10-20): a create whose reply never reached the gate leaves a
// profile whose 12-word recovery code was never shown. The daemon keeps the words it just minted in its OWN MEMORY
// for createCodeMemoTTL, or until the next sign-in, and a repeat create with the same name and passphrase that gets
// EXISTS hands them over once (createPrecheck), then forgets them.
//
// NWP-20261116-04 (h46 #7, docs/product-decisions.md 2026-10-28): the memo also keeps the words of a Save to your
// store (PROMOTE2) whose reply was lost. They live in the same map under their OWN key prefix (promoteCodeMemoKey), so
// the purge and every sign-in end them too, and a repeat CREATE with the same name and passphrase never takes them:
// only a repeat PROMOTE2 from the session that saved does (promoteGuards).
//
// NWP-20261123-28: the window is measured on CLOCK_BOOTTIME (bootNowMs, createCodeMemoClock), not on Go's monotonic
// clock. On Linux that clock is CLOCK_MONOTONIC, which STOPS while the phone is suspended (push_clock.go and
// sleepBootSteps in end_unsaved.go record the same trap), so a phone that slept after a lost reply kept the words for as
// long as it slept. When the boot clock cannot be read, the memo keeps no words and expires every entry (fail closed).
//
// RAM ONLY: never written to disk, never logged, and gone if the daemon restarts (the decision accepts that cost).
// The map is keyed by a hash of the profile ref, so even a memory dump does not list profile names beside words.
const createCodeMemoTTL = 5 * time.Minute

type createdCode struct {
	words string
	until time.Time
}

var (
	createCodeMemoMu  sync.Mutex
	createCodeMemo    = map[string]createdCode{}
	createCodeMemoNow = createCodeMemoClock // tests inject the clock here
)

// createCodeMemoClock is CLOCK_BOOTTIME (bootNowMs) as a time.Time with no monotonic reading, so Add and Before count
// the time the phone spent asleep; the zero time when the boot clock cannot be read. It never falls back to time.Now:
// an until on one clock tested against a now on the other fails OPEN.
func createCodeMemoClock() time.Time {
	if ms := bootNowMs(); ms > 0 {
		return time.UnixMilli(ms)
	}
	return time.Time{}
}

func createCodeMemoKey(name, pass string) string {
	sum := sha256.Sum256([]byte("nowhere-create-memo\x00" + profileRefV2(name, pass)))
	return hex.EncodeToString(sum[:])
}

// promoteCodeMemoKey is the key of a save's words: its own prefix, so a create never finds them.
func promoteCodeMemoKey(name, pass string) string {
	sum := sha256.Sum256([]byte("nowhere-promote-memo\x00" + profileRefV2(name, pass)))
	return hex.EncodeToString(sum[:])
}

// rememberCreatedCode keeps the words a successful create minted for (name, pass).
func rememberCreatedCode(name, pass, words string) {
	rememberCode(createCodeMemoKey(name, pass), words)
}

// takeCreatedCode returns the unexpired words a create minted for (name, pass) and deletes them.
func takeCreatedCode(name, pass string) string {
	return takeCode(createCodeMemoKey(name, pass))
}

// rememberPromotedCode keeps the words a successful save (promoteToStore) minted for (name, pass).
func rememberPromotedCode(name, pass, words string) {
	rememberCode(promoteCodeMemoKey(name, pass), words)
}

// takePromotedCode returns the unexpired words a save minted for (name, pass) and deletes them.
func takePromotedCode(name, pass string) string {
	return takeCode(promoteCodeMemoKey(name, pass))
}

// rememberCode keeps words under k for createCodeMemoTTL; on an unreadable clock it keeps nothing.
func rememberCode(k, words string) {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	purgeExpiredLocked(createCodeMemoNow()) // an earlier entry's words do not outlive their window because a new one came
	now := createCodeMemoNow()
	if now.IsZero() {
		return
	}
	createCodeMemo[k] = createdCode{words: words, until: now.Add(createCodeMemoTTL)}
}

// takeCode returns the unexpired words under k and deletes them; an expired entry is dropped and "" returned.
func takeCode(k string) string {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	e, ok := createCodeMemo[k]
	if !ok {
		return ""
	}
	delete(createCodeMemo, k)
	if createCodeMemoNow().IsZero() {
		return ""
	}
	if !createCodeMemoNow().Before(e.until) {
		return ""
	}
	return e.words
}

// purgeExpiredCreatedCodes drops every entry whose window is over. The login daemon calls it once per sync cycle
// (syncLoop), so words nobody asked for do not sit in RAM until the next sign-in or a repeat create.
func purgeExpiredCreatedCodes() {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	purgeExpiredLocked(createCodeMemoNow())
}

// purgeExpiredLocked deletes the entries whose until is not after now, and every entry when now is the zero time (an
// unreadable clock); the caller holds createCodeMemoMu.
func purgeExpiredLocked(now time.Time) {
	if now.IsZero() {
		clear(createCodeMemo)
		return
	}
	for key, e := range createCodeMemo {
		if !now.Before(e.until) {
			delete(createCodeMemo, key)
		}
	}
}

// forgetCreatedCodes ends the window: any sign-in does.
func forgetCreatedCodes() {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	clear(createCodeMemo)
}
