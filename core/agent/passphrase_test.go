package main

import (
	"math"
	"strings"
	"testing"

	bip39 "github.com/tyler-smith/go-bip39"
)

// #79: the strength floor accepts strong inputs and rejects below-floor / trivial ones with a reason.
func TestPassphraseFloor(t *testing.T) {
	strong := []struct{ name, pass string }{
		{"alice", "correct horse battery staple"}, // 4 words, 28 chars
		{"bob", "a wildly long single phrase!!"},  // >= 12 chars
		{"cara", "river maple stone cloud"},       // 4 words, 23 chars
		{"dev", "Tr0ub4dour-and-more"},            // >= 12 chars, mixed
		{"erin", "correct horse battery"},         // 3 words, 21 chars
		{"finn", "lanternfjord"},                  // one word, exactly 12 chars
		{"gwen", "ox fig an ek"},                  // 4 distinct words, exactly 12 chars
		{"hana", "maple river  stone"},            // a double space, still 17 chars after the collapse (dn-1107 #5)
	}
	for _, c := range strong {
		if ok, reason := passphraseStrong(c.name, c.pass); !ok {
			t.Errorf("passphraseStrong(%q, %q) = false (%s); want strong", c.name, c.pass, reason)
		}
	}

	weak := []struct {
		name, pass, wantSubstr string
	}{
		{"alice", "short", "too short"},
		{"alice", "c1234", "too short"}, // Chester's throwaway shape
		{"alice", "alice", "too short"}, // and too short anyway
		{"bob", "bob", "too short"},
		{"cara", "cara", "too short"},
		{"aaaa", "aaaaaaaaaaaa", "repetitive"}, // 12 chars, one rune
		{"q", "qwertyuiop12", "keyboard"},      // 12 chars, a walk
		{"x", "1234567890ab", "keyboard"},      // walk prefix
		{"y", "password1234", "commonly used"}, // 12 chars, famous
		{"z", "ab ab ab ab", "too short"},      // 4 words, 11 chars
		{"profileX", "profilex", "too short"},
	}
	for _, c := range weak {
		ok, reason := passphraseStrong(c.name, c.pass)
		if ok {
			t.Errorf("passphraseStrong(%q, %q) = true; want weak", c.name, c.pass)
			continue
		}
		if !strings.Contains(reason, c.wantSubstr) {
			t.Errorf("passphraseStrong(%q, %q) reason = %q; want substring %q", c.name, c.pass, reason, c.wantSubstr)
		}
	}
}

// The exact reasons: "too short" alone would let the old "..., or 4 words" text pass for the new one, and the
// distinct-words check must say the number it checks.
func TestPassphraseFloorReasons(t *testing.T) {
	const short = "too short — use at least 12 characters"
	const distinct = "use at least 3 different words"
	cases := []struct{ name, pass, want string }{
		{"h1", "1 2 3 4", short},                // four one-character words, 7 chars
		{"h2", "a b c d", short},                // 7 chars
		{"h3", "ab cd ef gh", short},            // 11 chars, one short of the floor
		{"h4", "abcd abcd abcd abcd", distinct}, // 19 chars, 1 distinct word
		{"h5", "ab ab ab ab ab", distinct},      // 14 chars, 1 distinct word
		{"h6", "abc abc abc def def", distinct}, // 2 distinct words
		// dn-1107 #5: the count is taken after the ends are trimmed and each whitespace run is collapsed to one space.
		{"s1", strings.Repeat(" ", 12), short},       // twelve spaces: 0 chars after the collapse
		{"s2", "a" + strings.Repeat(" ", 11), short}, // one letter and eleven spaces: 1 char
		{"s3", strings.Repeat(" ", 11) + "a", short}, // eleven spaces and one letter: 1 char
		{"s4", "ab\n\t\t\t\t\t\t\t\t\t", short},      // a newline and nine tabs: 2 chars
		{"s5", " river stone", short},                // a leading space: 11 chars
		{"s6", "river  stone", short},                // a double space: 11 chars
	}
	for _, c := range cases {
		ok, reason := passphraseStrong(c.name, c.pass)
		if ok {
			t.Errorf("passphraseStrong(%q, %q) = true; want %q", c.name, c.pass, c.want)
		} else if reason != c.want {
			t.Errorf("passphraseStrong(%q, %q) reason = %q; want %q", c.name, c.pass, reason, c.want)
		}
	}
}

// dn-1023 #11: a phrase made of one repeated word or unit is refused at any word count and any length, with
// the existing repeat reason, byte for byte (the meter shows no new text).
func TestPassphraseFloorRepeatedUnit(t *testing.T) {
	const repetitive = "too repetitive — mix in more variety"
	weak := []struct{ name, pass string }{
		{"alice", "alice alice alice"}, // 3 words, one word said three times
		{"r1", "abcdabcdabcd"},         // one 12-character word, a 4-rune unit three times
		{"r2", "abcdefabcdef"},         // a 6-rune unit twice: the period is exactly half
		{"r3", "Alice ALICE alice"},    // case does not hide the repeat
		{"r4", "abcdeabcdeab"},         // a 5-rune unit twice plus a trailing part
		{"r5", "abcdabcd abcd"},        // the space does not hide the repeat
	}
	for _, c := range weak {
		ok, reason := passphraseStrong(c.name, c.pass)
		if ok {
			t.Errorf("passphraseStrong(%q, %q) = true; want %q", c.name, c.pass, repetitive)
		} else if reason != repetitive {
			t.Errorf("passphraseStrong(%q, %q) reason = %q; want %q", c.name, c.pass, reason, repetitive)
		}
	}
	strong := []struct{ name, pass string }{
		{"s1", "river river stone"},     // a word said twice, then another: no single unit
		{"s2", "correct horse correct"}, // the first word again at the end
		{"gwen", "ox fig an ek"},        // 4 distinct words, exactly 12 chars
		{"finn", "lanternfjord"},        // one word, exactly 12 chars
	}
	for _, c := range strong {
		if ok, reason := passphraseStrong(c.name, c.pass); !ok {
			t.Errorf("passphraseStrong(%q, %q) = false (%s); want strong", c.name, c.pass, reason)
		}
	}
}

// A profile name equal to the passphrase is refused even when it clears the length bar.
func TestPassphraseRejectsName(t *testing.T) {
	if ok, reason := passphraseStrong("longprofilename", "longprofilename"); ok {
		t.Fatalf("pass == name accepted; want refused")
	} else if !strings.Contains(reason, "profile name") {
		t.Fatalf("reason = %q; want the profile-name reason", reason)
	}
}

// The generator always clears the floor (genPassphraseWords words from a 2048-word list) and is non-repeating.
func TestGeneratePassphrase(t *testing.T) {
	// The constant may never drop below the 50-bit floor docs/owner-claim-spec.md states (NWP-20261011-18).
	list := bip39.GetWordList()
	if len(list) != 2048 {
		t.Fatalf("bip39 list has %d words; the 55-bit figure in passphrase.go assumes 2048", len(list))
	}
	if bits := float64(genPassphraseWords) * math.Log2(float64(len(list))); bits < 50 {
		t.Fatalf("genPassphraseWords=%d gives %.1f bits; the floor is 50", genPassphraseWords, bits)
	}
	seen := map[string]int{}
	for i := 0; i < 50; i++ {
		p := generatePassphrase()
		if len(strings.Fields(p)) != genPassphraseWords {
			t.Fatalf("generatePassphrase() = %q; want %d words", p, genPassphraseWords)
		}
		if ok, reason := passphraseStrong("someone", p); !ok {
			t.Fatalf("generated %q fails the floor: %s", p, reason)
		}
		seen[p]++
	}
	if len(seen) < 40 { // 50 draws from ~2048^5 space should almost never collide
		t.Fatalf("generator produced only %d distinct of 50 -- suspiciously low entropy", len(seen))
	}
}
