package main

// NWP-20261016-29: every verb the chooser sends over nowhere_login has an explicit daemon arm.
//
// handleLogin dispatches on the request's first line and anything that matches no arm falls through to the legacy
// Arc-1 login, which wipes the session state dir (see SUBSCRIBE, OTA-REFRESH and handleRoamIn's key mode, each of
// which keeps a verb or a line shape for that reason). The chooser is a priv-app that is not hot-patchable while the
// agent is, so the skew runs one way: an agent that retires or renames a verb an installed chooser still sends wipes
// state. Nothing compared the two sets until this file.
//
// Both sides are PARSED, not grepped: the Go side with go/parser (every literal handleLogin compares the request
// name with, plus the predicate functions it calls with it, which are CALLED), the Java side with a small lexer that
// knows comments, strings and brace nesting. Source roots can be redirected with NOWHERE_VERBS_AGENT_DIR and
// NOWHERE_VERBS_CHOOSER_SRC so a mutated copy can be pointed at without editing the tree.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

var verbRe = regexp.MustCompile(`^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$`)

// armPredicates are the functions handleLogin calls with the request name to route a whole family of verbs. They are
// CALLED here, not parsed. A new `...Cmd(name)` call in handleLogin that is in neither list fails the test.
var armPredicates = map[string]func(string) bool{
	"telCmd":        telCmd,
	"ownerKeyCmd":   ownerKeyCmd,
	"ownerInboxCmd": ownerInboxCmd,
	"seTieCmd":      seTieCmd,
}

// notArms are the name-taking functions in handleLogin that classify a verb or gate its caller, never route it.
var notArms = map[string]bool{
	"concurrentSafeCmd":      true,
	"refusedOwnerModeCaller": true,
	"rekeyHoldingVerb":       true,
	"handleTelCmd":           true, // the handler telCmd routes to
}

type loginArms struct {
	exact    map[string]bool
	prefixes []string
	preds    map[string]func(string) bool
}

func (a *loginArms) has(verb string) bool {
	if a.exact[verb] {
		return true
	}
	for _, p := range a.prefixes {
		if strings.HasPrefix(verb, p) {
			return true
		}
	}
	for _, f := range a.preds {
		if f(verb) {
			return true
		}
	}
	return false
}

func agentDir() string {
	if d := os.Getenv("NOWHERE_VERBS_AGENT_DIR"); d != "" {
		return d
	}
	return "."
}

func chooserSrcDir() string {
	if d := os.Getenv("NOWHERE_VERBS_CHOOSER_SRC"); d != "" {
		return d
	}
	return filepath.Join("..", "chooser", "src")
}

func isNameIdent(e ast.Expr) bool {
	id, ok := e.(*ast.Ident)
	return ok && id.Name == "name"
}

func strLit(e ast.Expr) (string, bool) {
	bl, ok := e.(*ast.BasicLit)
	if !ok || bl.Kind != token.STRING {
		return "", false
	}
	s, err := strconv.Unquote(bl.Value)
	return s, err == nil
}

func parseLoginArms(t *testing.T) *loginArms {
	t.Helper()
	fset := token.NewFileSet()
	var handle *ast.FuncDecl
	for _, f := range []string{"main.go"} {
		file, err := parser.ParseFile(fset, filepath.Join(agentDir(), f), nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		for _, d := range file.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == "handleLogin" {
				handle = fd
			}
		}
	}
	if handle == nil || handle.Body == nil {
		t.Fatal("handleLogin not found in main.go")
	}
	arms := &loginArms{exact: map[string]bool{}, preds: map[string]func(string) bool{}}
	called := map[string]bool{}
	ast.Inspect(handle.Body, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.BinaryExpr:
			if x.Op == token.EQL {
				if isNameIdent(x.X) {
					if s, ok := strLit(x.Y); ok {
						arms.exact[s] = true
					}
				} else if isNameIdent(x.Y) {
					if s, ok := strLit(x.X); ok {
						arms.exact[s] = true
					}
				}
			}
		case *ast.SwitchStmt:
			if x.Tag != nil && isNameIdent(x.Tag) {
				for _, c := range x.Body.List {
					for _, e := range c.(*ast.CaseClause).List {
						if s, ok := strLit(e); ok {
							arms.exact[s] = true
						}
					}
				}
			}
		case *ast.CallExpr:
			switch fn := x.Fun.(type) {
			case *ast.SelectorExpr:
				if pk, ok := fn.X.(*ast.Ident); ok && pk.Name == "strings" && fn.Sel.Name == "HasPrefix" && len(x.Args) == 2 && isNameIdent(x.Args[0]) {
					if s, ok := strLit(x.Args[1]); ok {
						arms.prefixes = append(arms.prefixes, s)
					}
				}
			case *ast.Ident:
				for _, a := range x.Args {
					if isNameIdent(a) {
						called[fn.Name] = true
					}
				}
			}
		}
		return true
	})
	for fn := range called {
		if f, ok := armPredicates[fn]; ok {
			arms.preds[fn] = f
		} else if !notArms[fn] && strings.HasSuffix(fn, "Cmd") {
			t.Errorf("handleLogin routes on %s(name), which daemon_verbs_test.go does not know: add it to armPredicates (an arm) or notArms (a classifier)", fn)
		}
	}
	for fn := range armPredicates {
		if !called[fn] {
			t.Errorf("handleLogin no longer calls %s(name): drop it from armPredicates", fn)
		}
	}
	// Only verb-shaped literals are arms; the rest are comparisons of the request name against something else.
	for s := range arms.exact {
		if !verbRe.MatchString(s) {
			delete(arms.exact, s)
		}
	}
	sort.Strings(arms.prefixes)
	return arms
}

// ---- Java side ---------------------------------------------------------------------------------------------------

type jtok struct {
	kind string // "id", "str", "chr", "p" (punctuation)
	text string // identifier / decoded string / punctuation
	line int
}

func unescapeJava(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func lexJava(src string) []jtok {
	var out []jtok
	line := 1
	for i := 0; i < len(src); {
		c := src[i]
		switch {
		case c == '\n':
			line++
			i++
		case c == ' ' || c == '\t' || c == '\r':
			i++
		case strings.HasPrefix(src[i:], "//"):
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case strings.HasPrefix(src[i:], "/*"):
			j := strings.Index(src[i+2:], "*/")
			if j < 0 {
				j = len(src) - i - 2
			}
			line += strings.Count(src[i:i+2+j], "\n")
			i += 2 + j + 2
		case c == '"' || c == '\'':
			j := i + 1
			for j < len(src) && src[j] != c {
				if src[j] == '\\' {
					j++
				}
				j++
			}
			body := src[i+1 : min(j, len(src))]
			k := "str"
			if c == '\'' {
				k = "chr"
			}
			out = append(out, jtok{k, unescapeJava(body), line})
			i = j + 1
		case c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9':
			j := i
			for j < len(src) && (src[j] == '_' || src[j] == '$' || src[j] >= 'a' && src[j] <= 'z' || src[j] >= 'A' && src[j] <= 'Z' || src[j] >= '0' && src[j] <= '9') {
				j++
			}
			out = append(out, jtok{"id", src[i:j], line})
			i = j
		default:
			if strings.HasPrefix(src[i:], "->") {
				out = append(out, jtok{"p", "->", line})
				i += 2
				continue
			}
			out = append(out, jtok{"p", string(c), line})
			i++
		}
	}
	return out
}

var javaKeywords = map[string]bool{"if": true, "for": true, "while": true, "switch": true, "catch": true, "synchronized": true,
	"return": true, "new": true, "else": true, "throw": true, "case": true, "do": true, "try": true, "assert": true}

// methodSpan is a method (or constructor) body in token indexes, found by brace nesting.
type methodSpan struct {
	name     string
	from, to int // token indexes of '{' and its matching '}'
}

func methodSpans(toks []jtok) []methodSpan {
	var spans []methodSpan
	for i, tk := range toks {
		if tk.kind != "p" || tk.text != "{" {
			continue
		}
		// walk back over `throws A, B` to the closing ')' of the parameter list
		j := i - 1
		for j >= 0 && toks[j].kind == "id" || j >= 0 && toks[j].text == "," || j >= 0 && toks[j].text == "." {
			if toks[j].kind == "id" && toks[j].text == "throws" {
				j--
				break
			}
			j--
		}
		if j < 0 || toks[j].text != ")" {
			continue
		}
		depth, k := 0, j
		for ; k >= 0; k-- {
			if toks[k].text == ")" && toks[k].kind == "p" {
				depth++
			} else if toks[k].text == "(" && toks[k].kind == "p" {
				depth--
				if depth == 0 {
					break
				}
			}
		}
		if k < 1 || toks[k-1].kind != "id" || javaKeywords[toks[k-1].text] {
			continue
		}
		if k >= 2 {
			pv := toks[k-2]
			// `new Foo(...) {` is an anonymous class, `x = foo(...) {` is not Java: a method name follows a type, a
			// modifier, an annotation's ')' or a block boundary
			if pv.text == "new" || pv.text == "=" || pv.text == "." || pv.text == "(" || pv.text == "," || pv.text == "->" || pv.text == "+" {
				continue
			}
		}
		// the matching close brace
		d, e := 0, i
		for ; e < len(toks); e++ {
			if toks[e].kind == "p" && toks[e].text == "{" {
				d++
			} else if toks[e].kind == "p" && toks[e].text == "}" {
				d--
				if d == 0 {
					break
				}
			}
		}
		spans = append(spans, methodSpan{toks[k-1].text, i, e})
	}
	return spans
}

// enclosing returns the innermost method containing token idx ("" at class level).
func enclosing(spans []methodSpan, idx int) *methodSpan {
	var best *methodSpan
	for i := range spans {
		s := &spans[i]
		if idx > s.from && idx < s.to && (best == nil || s.to-s.from < best.to-best.from) {
			best = s
		}
	}
	return best
}

// nthArg returns the tokens of argument n (0-based) of the call whose '(' is at toks[open].
func nthArg(toks []jtok, open, n int) []jtok {
	depth, from := 0, open+1
	for i := open; i < len(toks); i++ {
		if toks[i].kind != "p" {
			continue
		}
		switch toks[i].text {
		case "(", "[", "{":
			depth++
		case ")", "]", "}":
			depth--
			if depth == 0 {
				if n == 0 {
					return toks[from:i]
				}
				return nil
			}
		case ",":
			if depth == 1 {
				if n == 0 {
					return toks[from:i]
				}
				n--
				from = i + 1
			}
		}
	}
	return nil
}

// leadingVerb extracts the request's first-line verb from an argument expression: its leading string literal up to a
// "\n" or a space, or the literal itself when what follows it is a delimiter (`+ "\n"`, `+ (char) 10`) or nothing.
// ok is false when the argument does not start with such a literal.
func leadingVerb(arg []jtok) (string, bool) {
	i := 0
	for i < len(arg) && arg[i].kind == "p" && arg[i].text == "(" { // `(("X\n" + a).getBytes(..))`
		i++
	}
	if i >= len(arg) || arg[i].kind != "str" {
		return "", false
	}
	lit := arg[i].text
	rest := arg[i+1:]
	if k := strings.IndexAny(lit, "\n "); k >= 0 {
		return lit[:k], verbRe.MatchString(lit[:k])
	}
	delim := len(rest) == 0 || rest[0].text == ")" || rest[0].text == "." || rest[0].text == ","
	if !delim && len(rest) >= 2 && rest[0].text == "+" {
		n := rest[1]
		delim = n.kind == "str" && strings.HasPrefix(n.text, "\n") ||
			n.text == "(" && len(rest) >= 5 && rest[2].text == "char" && rest[4].text == "10"
	}
	return lit, delim && verbRe.MatchString(lit)
}

// senderSpec says where a call is a daemon send and which argument is the request.
type senderSpec struct {
	files []string // nil = any file
	qual  string   // required qualifier (`NfcFido2.run`), "" = none
	arg   int      // index of the request argument
}

// chooserSender names the calls whose arguments carry a daemon request. Every helper that wraps DaemonSocket is here;
// a new wrapper is caught twice: its own body is an opaque site (a socket write of a parameter) until it is listed in
// opaqueAllowed, and the file that holds it must be in senderFiles.
var chooserSender = map[string]senderSpec{
	"sendDaemon":           {files: []string{"ChooserActivity.java", "ProfileActivity.java"}},
	"sendDaemonLines":      {files: []string{"ChooserActivity.java"}},
	"createStreaming":      {files: []string{"ChooserActivity.java"}},
	"sendDaemonMulti":      {files: []string{"ProfileActivity.java"}},
	"sendDaemonReply":      {files: []string{"ProfileActivity.java"}},
	"daemonCmd":            {files: []string{"ChooserActivity.java"}},
	"pollDaemon":           {files: []string{"ChooserActivity.java"}},
	"daemonLenReply":       {files: []string{"ProfileActivity.java"}},
	"ownerKeyAsync":        {files: []string{"ChooserActivity.java"}},
	"ownerInboxReq":        {files: []string{"ChooserActivity.java"}},
	"runTieVerb":           {files: []string{"ProfileActivity.java"}},
	"roundTrip":            {},
	"roundTripLines":       {},
	"roundTripLinesOrNull": {},
	"roundTripLinesRaw":    {},
	"lenReply":             {files: []string{"DaemonSocket.java", "ProfileActivity.java", "StoreService.java"}},
	"daemon":               {files: []string{"UnarchiveService.java"}},
	"line":                 {files: []string{"StoreService.java"}},
	"fetchVerdict":         {files: []string{"StoreService.java"}},
	"send":                 {files: []string{"WifiMirror.java"}},
	"untilAnswered":        {files: []string{"SmsDeliverReceiver.java", "TelArrival.java"}},
	"run":                  {files: []string{"ProfileActivity.java"}, qual: "NfcFido2", arg: 1},
	"armGate":              {files: []string{"ChooserActivity.java"}, qual: "NfcFido2", arg: 1},
}

func senderFor(toks []jtok, i int, file string) (senderSpec, bool) {
	sp, ok := chooserSender[toks[i].text]
	if !ok {
		return sp, false
	}
	if sp.qual != "" && (i < 2 || toks[i-1].text != "." || toks[i-2].text != sp.qual) {
		return sp, false
	}
	if sp.files == nil {
		return sp, true
	}
	for _, f := range sp.files {
		if f == file {
			return sp, true
		}
	}
	return sp, false
}

type verbSite struct {
	verb, file string
	line       int
}

type opaqueSite struct {
	file, method string
	line         int
	call         string
}

// opaqueAllowed maps a send site whose request argument is not a literal ("file#enclosing method") to the verbs it can
// send. A NEW non-literal site fails the test until it is listed here with the verbs it can reach: each verb listed is
// then held to the same arm check as a literal one. An empty list is a site that only forwards a request its caller
// built -- the helper bodies themselves -- whose callers are checked as ordinary sender calls. A listed site that no
// longer exists fails too, so the list cannot rot.
var opaqueAllowed = map[string][]string{
	// ---- helper bodies: forward the caller's request; the callers are sender calls above
	"DaemonSocket.java#lenReply":             {},
	"DaemonSocket.java#roundTrip":            {},
	"DaemonSocket.java#roundTripLines":       {},
	"DaemonSocket.java#roundTripLinesOrNull": {},
	"DaemonSocket.java#roundTripLinesRaw":    {},
	"ChooserActivity.java#ownerKeyAsync":     {},
	"ChooserActivity.java#daemonCmd":         {},
	"ChooserActivity.java#sendDaemon":        {},
	"ChooserActivity.java#pollDaemon":        {},
	"ChooserActivity.java#sendDaemonLines":   {},
	"ChooserActivity.java#createStreaming":   {},
	"ProfileActivity.java#sendDaemon":        {},
	"ProfileActivity.java#sendDaemonMulti":   {},
	"ProfileActivity.java#sendDaemonReply":   {},
	"ProfileActivity.java#daemonLenReply":    {},
	"ProfileActivity.java#runTieVerb":        {},
	"StoreService.java#line":                 {},
	"StoreService.java#lenReply":             {},
	"StoreService.java#fetchVerdict":         {},
	"TelArrival.java#untilAnswered":          {},
	"UnarchiveService.java#daemon":           {},
	"WifiMirror.java#send":                   {},
	"NfcFido2.java#shuttle":                  {},
	// ---- call sites whose request is built from a variable or a ternary
	// The gate's Wi-Fi adopt record: WifiMirrorLine.adoptRequest builds the request.
	"ChooserActivity.java#maybeMirrorWifi": {"WIFI-ADOPT"},
	// The gate's NFC tap: buildGateNfcVerb() returns FIDO2-NFC-RESUME when resuming a session, else FIDO2-NFC-ASSERT.
	"ChooserActivity.java#tryArmGateNfc": {"FIDO2-NFC-RESUME", "FIDO2-NFC-ASSERT"},
	// ownerInboxReq(verb, tail) builds "<verb>\nv1\n..." and returns null without a session; the verb is its literal argument,
	// and these two roundTripLines calls send what it built for GET-OWNER-INBOX / READ-OWNER-ITEM.
	"ChooserActivity.java#buildOwnerInboxScreen":     {"GET-OWNER-INBOX"},
	"ChooserActivity.java#buildOwnerInboxItemScreen": {"READ-OWNER-ITEM"},
	// The sync watcher arms or disarms the prefetch, and picks one of four re-key states for the Tie screen.
	"ChooserActivity.java#startSyncStatusWatcher": {"PREFETCH-ARM", "PREFETCH-DISARM", "REKEY-WAIT-NET", "REKEY-WAIT-WIFI", "REKEY-ARM", "REKEY-WAIT-BATTERY"},
	// GATE-TRACE\n<event>: the event is the second line.
	"GateTrace.java#send": {"GATE-TRACE"},
	// The Tie screen's two buttons: tie, or untie.
	"ProfileActivity.java#showPhoneTie": {"SE-TIE", "SE-UNTIE"},
	// The Add credit screen's Redeem: PlanChoice.claimRequest builds "CLAIM\n<code>\n" when convert-or-keep was not
	// asked, else "CLAIM2\n<code>\n<keep|convert>\n" (NWP-20261031-11).
	"ProfileActivity.java#addCreditsScreen": {"CLAIM", "CLAIM2"},
	// The session probe: ProfileProbe.run sends GET-SESSION-TYPE, GET-OFFLINE, GET-SESSION-NAME,
	// "OTA-AFTER-LOGOFF\n0\n" and OTA-STATUS in that order through the roundTrip(msg) callback probeSession hands it,
	// stopping at the first with no answer (NWP-20261113-06).
	"ProfileActivity.java#probeSession": {"GET-SESSION-TYPE", "GET-OFFLINE", "GET-SESSION-NAME", "OTA-AFTER-LOGOFF", "OTA-STATUS"},
	// The Storage screen's wallet repair: showStorage sends WalletRepairCopy.CHECK_REQUEST, "REPAIR-WALLET\nCHECK\n",
	// and, from the dialog's positive button, CONFIRM_REQUEST, "REPAIR-WALLET\nCONFIRM\n" (NWP-20261103-06).
	"ProfileActivity.java#showStorage": {"REPAIR-WALLET"},
	// The logoff's inferred-orphan list: "EXPECT-SHRINK-INFERRED\n" then the package names, appended to a builder. It
	// is in doLogoffImpl, the body doLogoff() and doLogoffForInstall() share since NWP-20261017-17.
	"ProfileActivity.java#doLogoffImpl": {"EXPECT-SHRINK-INFERRED"},
	// The gate's rollback fallback: gateRollbackRequest(name, pw, se) builds "ROLLBACK-GATE\n<name>\n<pass>\n<se>\n" (NWP-20261016-20).
	"ChooserActivity.java#doGateRollback": {"ROLLBACK-GATE"},
	// The gate's credit-lost notice: OK sends creditLostClearCommand(stamp), "CLEAR-CREDIT-LOST\n<stamp>\n" (NWP-20261013-20).
	"ChooserActivity.java#refreshCreditLostNotice": {"CLEAR-CREDIT-LOST"},
	// The cold lock's re-check: WipeOnSave.recheckVerb(onSave) picks the verb (Q138, NWP-20261106-14).
	"ChooserActivity.java#evictRecheck": {"EVICT-RECHECK", "EVICT-RECHECK-SAVED"},
	// The passphrase change: changeOwnerPass sends what OwnerPassChange.rewrapRequest built, "OWNER-KEY-REWRAP\nv1\n..." (NWP-20261022-01).
	"ChooserActivity.java#changeOwnerPass": {"OWNER-KEY-REWRAP"},
	// The arrival: TelArrival.telRequest / mmsRequest build "SEAL-TEL\nv2\n..." and "SEAL-MMS\nv2\n...".
	"SmsDeliverReceiver.java#sealAndNotify":    {"SEAL-TEL"},
	"SmsDeliverReceiver.java#sealMmsAndNotify": {"SEAL-MMS"},
	// The Auto sweep's per-app outcome: SweepOutcome.request(i, n, token, ms) builds "AUTO-SWEEP-APP\n<i>\n<n>\n<token>\n<ms>\n",
	// sent once per app and once for a sign-out's stop (NWP-20261113-17).
	"UnarchiveService.java#sweepAuto": {"AUTO-SWEEP-APP"},
	// The Auto sweep's restore-only retries: OdRestoreList.request(keep) builds "RESTORE-ODDATA\n<pkg> <pkg>...\n" for
	// 2..OdRestoreList.CHUNK apps in one request (NWP-20261128-16).
	"UnarchiveService.java#restoreOnlyListLocked": {"RESTORE-ODDATA"},
	// First run's phone name: saveDeviceName sends DeviceName.request(label), "SET-DEVICE-LABEL\n<label>\n" (NWP-20261114-28).
	"ChooserActivity.java#saveDeviceName": {"SET-DEVICE-LABEL"},
}

// streamReplies are literals written to a socket whose request is already open: answers to the daemon's prompts, not
// request verbs. NfcFido2.shuttle relays the tag's APDU answers.
var streamReplies = map[string][]string{
	"NfcFido2.java#shuttle": {"NFCERR", "RESP"},
}

// scanChooser walks the chooser sources and returns the literal verb sites and the non-literal sites.
func scanChooser(t *testing.T) (verbs []verbSite, opaque []opaqueSite) {
	t.Helper()
	root := chooserSrcDir()
	var files []string
	filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && strings.HasSuffix(p, ".java") {
			files = append(files, p)
		}
		return nil
	})
	if len(files) < 20 {
		t.Fatalf("only %d .java files under %s: the chooser source moved", len(files), root)
	}
	sort.Strings(files)
	for _, p := range files {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		base := filepath.Base(p)
		toks := lexJava(string(b))
		spans := methodSpans(toks)
		touches := strings.Contains(string(b), "DaemonSocket") || strings.Contains(string(b), "LocalSocket") || strings.Contains(string(b), "nowhere_login")
		if touches && !senderFiles[base] {
			t.Errorf("%s talks to the daemon socket but daemon_verbs_test.go does not know it: add it to senderFiles after listing its send sites", base)
		}
		for i, tk := range toks {
			if tk.kind != "id" || i+1 >= len(toks) || toks[i+1].text != "(" || toks[i+1].kind != "p" {
				continue
			}
			isCall := false
			site := ""
			var spec senderSpec
			switch {
			case tk.text == "write":
				// a raw socket write: `.write(<bytes of a request>)` inside a method that holds a LocalSocket
				if i == 0 || toks[i-1].text != "." {
					continue
				}
				m := enclosing(spans, i)
				if m == nil {
					continue
				}
				holdsSocket := false
				for _, x := range toks[m.from:m.to] {
					if x.kind == "id" && (x.text == "LocalSocket" || x.text == "getOutputStream") {
						holdsSocket = true
					}
				}
				arg := nthArg(toks, i+1, 0)
				hasBytes := false
				for _, x := range arg {
					if x.text == "getBytes" {
						hasBytes = true
					}
				}
				isCall = holdsSocket && hasBytes
				site = "write"
			case func() bool { sp, ok := senderFor(toks, i, base); spec = sp; return ok }():
				// skip the declaration of the helper itself: `String sendDaemon(String msg) {`
				if i > 0 && (toks[i-1].kind == "id" && !javaKeywords[toks[i-1].text] || toks[i-1].text == ">" || toks[i-1].text == "]") {
					continue
				}
				isCall = true
				site = tk.text
			}
			if !isCall {
				continue
			}
			arg := nthArg(toks, i+1, spec.arg)
			m := enclosing(spans, i)
			method := "<class>"
			if m != nil {
				method = m.name
			}
			if v, ok := leadingVerb(arg); ok {
				if verbIn(streamReplies[base+"#"+method], v) {
					continue
				}
				verbs = append(verbs, verbSite{v, base, tk.line})
				continue
			}

			opaque = append(opaque, opaqueSite{base, method, tk.line, site})
		}
	}
	return
}

func verbIn(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// senderFiles are the chooser files that touch the daemon socket. A file that starts to and is not here fails.
var senderFiles = map[string]bool{
	"AppInstallReceiver.java": true, "BackupNowReceiver.java": true, "ChooserActivity.java": true,
	"CredentialService.java": true, "DaemonSocket.java": true, "DiagReportJob.java": true, "DozeAppsMirror.java": true, "GateAlarmActivity.java": true, "GateTrace.java": true,
	"IdleLogoffReceiver.java": true, "Ingest.java": true, "NfcFido2.java": true, "OtaUpdate.java": true,
	"OtaTimeReceiver.java": true, "OtaWakeReceiver.java": true, "ProfileActivity.java": true, "ReloginReceiver.java": true,
	"SmsDeliverReceiver.java": true, "StoreService.java": true, "TelArrival.java": true, "TelIngest.java": true,
	"UnarchiveService.java": true, "WifiMirror.java": true,
}

func TestDaemonVerbs(t *testing.T) {
	arms := parseLoginArms(t)
	if n := len(arms.exact) + len(arms.prefixes); n < 100 {
		t.Fatalf("only %d daemon arms parsed out of handleLogin: the parse matched nothing useful", n)
	}
	verbs, opaque := scanChooser(t)

	// every non-literal send site is listed, and every listed site still exists
	seen := map[string]bool{}
	sent := map[string][]verbSite{}
	for _, v := range verbs {
		sent[v.verb] = append(sent[v.verb], v)
	}
	for _, o := range opaque {
		key := o.file + "#" + o.method
		seen[key] = true
		vs, ok := opaqueAllowed[key]
		if !ok {
			t.Errorf("%s:%d (%s) sends a request that is not a string literal and %s is not in opaqueAllowed: list the verbs it can send", o.file, o.line, o.call, key)
			continue
		}
		for _, v := range vs {
			sent[v] = append(sent[v], verbSite{v, o.file, o.line})
		}
	}
	for key := range opaqueAllowed {
		if !seen[key] {
			t.Errorf("opaqueAllowed lists %s but no non-literal send site is there any more: drop it", key)
		}
	}
	if len(sent) < 50 {
		t.Fatalf("only %d chooser verbs found: the scan matched nothing useful", len(sent))
	}

	var names []string
	for v := range sent {
		names = append(names, v)
	}
	sort.Strings(names)
	for _, v := range names {
		if !verbRe.MatchString(v) {
			t.Errorf("%s:%d sends %q, which is not a verb-shaped first line", sent[v][0].file, sent[v][0].line, v)
			continue
		}
		if !arms.has(v) {
			for _, s := range sent[v] {
				t.Errorf("%s:%d sends %s, which has no arm in handleLogin: it falls through to the legacy login, which wipes the session state dir", s.file, s.line, v)
			}
		}
	}

	// the reverse is informational: agent-internal verbs and retired-but-kept ones (SUBSCRIBE) are legitimate
	var unsent []string
	for v := range arms.exact {
		if _, ok := sent[v]; !ok && !telCmd(v) && !ownerKeyCmd(v) && !ownerInboxCmd(v) {
			unsent = append(unsent, v)
		}
	}
	sort.Strings(unsent)
	t.Logf("daemon arms: %d exact, %d prefix, %d predicates; chooser verbs: %d (%d literal sites); arms no chooser sends: %d",
		len(arms.exact), len(arms.prefixes), len(arms.preds), len(sent), len(verbs), len(unsent))
	t.Logf("arms no chooser sends (informational): %s", strings.Join(unsent, " "))
}
