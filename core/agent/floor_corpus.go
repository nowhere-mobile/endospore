package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// floor-corpus (NWP-20261119-24, h49 #5 in docs/product-decisions.md; backlog row "The passphrase floor's rule has
// never been checked against a zxcvbn corpus"): runs the typed-passphrase floor over a list, and over weak phrases
// built from a word list, so the build server can show which entries of zxcvbn's own lists the floor admits.
// docs/credential-tiers.md ("Running the floor against zxcvbn's list") has the procedure; ci/floor-corpus-score.py
// adds zxcvbn's score to each pass.
//
// A HOST TOOL: it is never on the device's daemon path, starts no goroutine and writes no file. It calls the
// shipped passphraseStrong with an empty profile name and holds no rule of its own -- not floorCheckCLI either,
// because NOWHERE_PASS_FLOOR=0 bypasses that wrapper and a corpus run must report the true rule.
// TestFloorCorpusCallsTheShippedRule pins that.

const (
	floorCorpusTop   = 200 // --top default: how many words of the word list the phrases are built from
	floorCorpusGridK = 10  // the grid uses the first K words: K^4 phrases (10,000 at K = 10)
)

type floorCorpusPass struct {
	P string `json:"p"`
}

// floorCorpusCheck is the file's ONLY use of the floor: the shipped rule, an empty profile name.
func floorCorpusCheck(entry string) bool {
	ok, _ := passphraseStrong("", entry)
	return ok
}

// floorCorpusEmit prints entry as one JSON line when the floor passes it; a refused entry prints nothing.
func floorCorpusEmit(enc *json.Encoder, entry string) (bool, error) {
	if !floorCorpusCheck(entry) {
		return false, nil
	}
	return true, enc.Encode(floorCorpusPass{P: entry})
}

// floorCorpusCLI is `floor-corpus <list> [--words <wordlist> [--top <n>]]`. Stdout: one {"p": ...} line per pass.
// Stderr: the counts, the total last. Exit 0; 2 on a usage error; 1 when a file cannot be read.
func floorCorpusCLI(args []string, stdout, stderr io.Writer) int {
	const usage = "usage: floor-corpus <list> [--words <wordlist> [--top <n>]]"
	var list, wordsPath string
	top, topSet := floorCorpusTop, false
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "--words", "--top":
			if i+1 >= len(args) || args[i+1] == "" {
				fmt.Fprintf(stderr, "floor-corpus: %s needs a value\n%s\n", a, usage)
				return 2
			}
			i++
			if a == "--words" {
				wordsPath = args[i]
				continue
			}
			n, err := strconv.Atoi(args[i])
			if err != nil || n < 1 {
				fmt.Fprintf(stderr, "floor-corpus: --top needs a whole number of 1 or more\n%s\n", usage)
				return 2
			}
			top, topSet = n, true
		default:
			if strings.HasPrefix(a, "--") || list != "" {
				fmt.Fprintf(stderr, "floor-corpus: unexpected argument %q\n%s\n", a, usage)
				return 2
			}
			list = a
		}
	}
	if list == "" {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	if topSet && wordsPath == "" {
		fmt.Fprintf(stderr, "floor-corpus: --top needs --words\n%s\n", usage)
		return 2
	}

	var words []string // read before the list pass, so an unreadable word list fails before any output
	if wordsPath != "" {
		var err error
		if words, err = floorCorpusReadWords(wordsPath, top); err != nil {
			fmt.Fprintf(stderr, "floor-corpus: words: %v\n", err)
			return 1
		}
	}
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	f, err := os.Open(list)
	if err != nil {
		fmt.Fprintf(stderr, "floor-corpus: list: %v\n", err)
		return 1
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	tested, passed := 0, 0
	for sc.Scan() {
		entry := strings.TrimSuffix(sc.Text(), "\r")
		if entry == "" {
			continue
		}
		tested++
		ok, err := floorCorpusEmit(enc, entry)
		if err != nil {
			fmt.Fprintf(stderr, "floor-corpus: write: %v\n", err)
			return 1
		}
		if ok {
			passed++
		}
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(stderr, "floor-corpus: list: %v\n", err)
		return 1
	}
	if wordsPath == "" {
		fmt.Fprintf(stderr, "%d tested, %d passed\n", tested, passed)
		return 0
	}

	wTested, wPassed := 0, 0
	for _, p := range floorCorpusPhrases(words) {
		wTested++
		ok, err := floorCorpusEmit(enc, p)
		if err != nil {
			fmt.Fprintf(stderr, "floor-corpus: write: %v\n", err)
			return 1
		}
		if ok {
			wPassed++
		}
	}
	fmt.Fprintf(stderr, "list: %d tested, %d passed\n", tested, passed)
	fmt.Fprintf(stderr, "words: %d tested, %d passed\n", wTested, wPassed)
	fmt.Fprintf(stderr, "%d tested, %d passed\n", tested+wTested, passed+wPassed)
	return 0
}

// floorCorpusReadWords returns the first `top` distinct words of a word list, lower-cased, in file order. A line
// is `<word> [<count>]` (zxcvbn's frequency lists); only its first field is read. Fewer words than `top` is not an
// error.
func floorCorpusReadWords(path string, top int) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	var words []string
	seen := map[string]bool{}
	for len(words) < top && sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 0 {
			continue
		}
		w := strings.ToLower(fields[0])
		if seen[w] {
			continue
		}
		seen[w] = true
		words = append(words, w)
	}
	return words, sc.Err()
}

// floorCorpusPhrases builds the weak phrases, in a fixed order, each once: (1) every 4-word phrase of the first
// K = min(floorCorpusGridK, len(words)) words, repetition allowed; (2) each word said four times; (3) the four
// 3-distinct-of-4 patterns of each run of three consecutive words; (4) the capitalised form of each phrase of
// (1)-(3). The grid already holds (2) and (3) for its own K words, so the count is
// 2*(K^4 + max(0, N-K) + 4*max(0, (N-2)-max(0, K-2))): 21,900 at the defaults (N = 200, K = 10).
func floorCorpusPhrases(words []string) []string {
	k := len(words)
	if k > floorCorpusGridK {
		k = floorCorpusGridK
	}
	var out []string
	seen := map[string]bool{}
	add := func(ws ...string) {
		p := strings.Join(ws, " ")
		if seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	for a := 0; a < k; a++ {
		for b := 0; b < k; b++ {
			for c := 0; c < k; c++ {
				for d := 0; d < k; d++ {
					add(words[a], words[b], words[c], words[d])
				}
			}
		}
	}
	for _, w := range words {
		add(w, w, w, w)
	}
	for i := 0; i+2 < len(words); i++ {
		a, b, c := words[i], words[i+1], words[i+2]
		add(a, a, b, c)
		add(a, b, a, c)
		add(a, b, c, a)
		add(a, b, c, c)
	}
	for _, p := range out { // range reads the lower-case slice once; add appends the capitalised forms after it
		ws := strings.Fields(p)
		for i, w := range ws {
			r, size := utf8.DecodeRuneInString(w)
			ws[i] = string(unicode.ToUpper(r)) + w[size:]
		}
		add(ws...)
	}
	return out
}
