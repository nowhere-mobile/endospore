package main

import (
	"crypto/rand"
	"math/big"
	"os"
	"strings"

	bip39 "github.com/tyler-smith/go-bip39"
)

// Passphrase strength floor + generator (#79, credential-tiers P1; docs/credential-tiers.md tier 1a).
//
// Enforced ONLY where data becomes durable -- create-vault, PROMOTE (throwaway -> store), rotate, recover --
// NEVER at login (blind login) and NEVER on throwaways (nothing crackable exists; friction would kill the
// feature). NIST 800-63B-aligned: a length/entropy floor, not composition rules. The agent is the backstop;
// the chooser mirrors it (CHECK-PASSPHRASE for a live meter, GEN-PASSPHRASE for the generator) so a refusal
// is never the user's first feedback.

// floorEnforced gates the whole floor. NOWHERE_PASS_FLOOR=0 bypasses it -- for tests (seeding fixed-pass
// fixtures) and as an emergency escape hatch; CHECK-PASSPHRASE still reports truthfully regardless.
func floorEnforced() bool { return os.Getenv("NOWHERE_PASS_FLOOR") != "0" }

// floorCheckCLI fails a CLI op with the weakness reason unless the floor is bypassed. `verb` prefixes the
// error (e.g. "rotate: too short — ...").
func floorCheckCLI(verb, name, pass string) {
	if !floorEnforced() {
		return
	}
	if ok, reason := passphraseStrong(name, pass); !ok {
		fail(verb + ": " + reason)
	}
}

const (
	floorMinChars = 12 // every typed passphrase needs >= 12 characters (a whitespace run counts as one space, the ends not at all), whatever its word count
	floorMinWords = 4  // a passphrase of this many words or more also needs >= 3 distinct words
)

// passphraseStrong applies the floor to (name, pass). Returns ok + a short, user-facing reason when it fails.
// The reason is safe to show verbatim (it never echoes the passphrase).
func passphraseStrong(name, pass string) (ok bool, reason string) {
	words := strings.Fields(pass)
	runes := []rune(strings.Join(words, " ")) // dn-1107 #5: the ends trimmed, each whitespace run counted as one space

	// Length/entropy floor: >= 12 characters, whatever the word count (dn-1025 #4, docs/product-decisions.md:
	// a phrase that passes on word count also needs 12 characters overall, so `1 2 3 4` no longer passes; the
	// word clause left the reason because it no longer admits anything shorter). The count is of the collapsed
	// form (dn-1107 #5): twelve spaces, or one letter and eleven spaces, are too short. Existing passphrases
	// still sign in, because sign-in never calls the floor.
	if len(runes) < floorMinChars {
		return false, "too short — use at least 12 characters"
	}

	// Blocklist -- catches inputs that clear the length bar but carry ~no entropy.
	low := strings.ToLower(strings.TrimSpace(pass))
	condensed := strings.ToLower(strings.Join(words, "")) // words joined, for walk/repeat checks

	if n := strings.ToLower(strings.TrimSpace(name)); n != "" && low == n {
		return false, "don't use your profile name as the passphrase"
	}
	if allSameRune(condensed) {
		return false, "too repetitive — mix in more variety"
	}
	if isKeyboardWalk(condensed) {
		return false, "avoid keyboard patterns like 'qwerty' or '123456'"
	}
	if commonPasswords[low] {
		return false, "that's a commonly used password — pick something more unique"
	}
	// A phrase of floorMinWords or more words needs some variety among them (kills "abcd abcd abcd abcd" and
	// "ab ab ab ab ab"): at least 3 distinct words. This is the build's restatement dn-1025 #4 asked for, not a
	// new rule: it used to guard the word-count-only pass, which is gone, so under its old condition it would be
	// dead code. A phrase of fewer words -- a 12-character single word included -- passes this check; the
	// repeated-unit check below still applies to it.
	if len(words) >= floorMinWords && distinctCount(words) < 3 {
		return false, "use at least 3 different words"
	}
	// One word or unit said again and again, at any word count (dn-1023 #11): "alice alice alice",
	// "abcdabcdabcd". It runs after the distinct-words check so a 4+-word phrase keeps that reason.
	if repeatsAUnit(condensed) {
		return false, "too repetitive — mix in more variety"
	}
	return true, ""
}

// genPassphraseWords is how many bip39 words generatePassphrase draws. 5 words x log2(2048) = 55 bits:
// the smallest count that clears the 50-bit floor docs/owner-claim-spec.md states for an anchored
// passphrase (4 words was 44 bits, below it -- NWP-20261011-18, closing the backlog row "The generated
// passphrase is 44 bits, not the 51.7 assumed"). Deliberately NOT raised toward the ~77 bits the export
// pages would need to call a backup folder "safe": that copy is counsel-gated (docs/privacy-claims.md).
// Distinct from floorMinWords, which is the floor for a passphrase the user TYPES.
const genPassphraseWords = 5

// generatePassphrase returns a diceware-style passphrase: genPassphraseWords words drawn uniformly
// (crypto/rand) from the bip39 English wordlist already shipped for the recovery mnemonic -- 55 bits,
// well above the typed floor, and the mnemonic is the forget-me backstop. Space-separated (a passphrase,
// not a bip39 seed phrase). TestGeneratePassphrase pins words*log2(len(list)) >= 50.
func generatePassphrase() string {
	list := bip39.GetWordList() // 2048 English words (default list)
	if len(list) == 0 {
		return ""
	}
	words := make([]string, genPassphraseWords)
	for i := range words {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(list))))
		check(err)
		words[i] = list[n.Int64()]
	}
	return strings.Join(words, " ")
}

func allSameRune(s string) bool {
	if len(s) < 2 {
		return false // "" / single rune isn't a "repeat"; length floor already handled the short case
	}
	first := []rune(s)[0]
	for _, r := range s {
		if r != first {
			return false
		}
	}
	return true
}

// repeatsAUnit reports whether s is one unit said at least twice in full, with a trailing part allowed
// ("abcdabcdabcd", "abcdeabcdeab"). passphraseStrong gives it condensed -- the words joined, lower-cased -- so
// case and spaces do not hide a repeat ("Alice ALICE alice", "abcd abcd abcd"). This is dn-1023 #11's "one
// repeated word or unit at any length" (docs/product-decisions.md); allSameRune is its one-rune case.
func repeatsAUnit(s string) bool {
	r := []rune(s)
	n := len(r)
	for p := 1; p <= n/2; p++ {
		match := true
		for i := p; i < n; i++ {
			if r[i] != r[i-p] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

func distinctCount(words []string) int {
	seen := map[string]struct{}{}
	for _, w := range words {
		seen[strings.ToLower(w)] = struct{}{}
	}
	return len(seen)
}

const walkWindow = 8 // an 8-char run along a keyboard/sequence line == a walk (catches walk+junk like "qwertyuiop12")

// isKeyboardWalk reports whether the condensed input CONTAINS a run (>= walkWindow chars) along a known
// keyboard/sequence line, forward or reversed -- so "qwertyuiop12" and "1234567890ab" are caught even though
// they clear the length bar. The window keeps a legit passphrase ("correct horse ...") from tripping on an
// incidental short sequence.
func isKeyboardWalk(condensed string) bool {
	r := []rune(condensed)
	if len(r) < walkWindow {
		return false
	}
	walks := []string{
		"1234567890",
		"qwertyuiop",
		"asdfghjkl",
		"zxcvbnm",
		"abcdefghijklmnopqrstuvwxyz",
	}
	for i := 0; i+walkWindow <= len(r); i++ {
		win := string(r[i : i+walkWindow])
		for _, w := range walks {
			if strings.Contains(w, win) || strings.Contains(reverse(w), win) {
				return true
			}
		}
	}
	return false
}

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}

// A small set of the most-abused passwords (already lowercased). Not exhaustive -- the length floor and the
// walk/repeat checks carry most of the weight; this catches the famous ones that happen to clear 12 chars.
var commonPasswords = map[string]bool{
	"password":     true,
	"password1":    true,
	"password123":  true,
	"password1234": true,
	"passw0rd":     true,
	"123456":       true,
	"1234567":      true,
	"12345678":     true,
	"123456789":    true,
	"1234567890":   true,
	"qwerty":       true,
	"qwertyuiop":   true,
	"letmein":      true,
	"iloveyou":     true,
	"admin":        true,
	"welcome":      true,
	"welcome123":   true,
	"monkey":       true,
	"dragon":       true,
	"football":     true,
	"baseball":     true,
	"superman":     true,
	"trustno1":     true,
	"changeme":     true,
	"whatever":     true,
	"starwars":     true,
	"letmein123":   true,
	"qwerty123":    true,
}
