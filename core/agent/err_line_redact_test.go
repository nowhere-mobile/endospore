package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// NWP-20261117-26 (docs/backlog.md, "A sign-in whose chunk fetch fails for good writes the whole presigned store
// URL, credential and signature included, into roam.log"). A store read that fails in transport panics with a
// storeReadErr around net/http's *url.Error, whose text is the whole presigned URL. These tests hold every line
// that prints such an error to logSafeErrText: no URL query, no head key.

var errLineHex64 = strings.Repeat("ab", 32)

// errLinePresigned is a presigned-looking GET URL for key on host. The credential and signature are the task's own
// example values, never a real key.
func errLinePresigned(host, key string) string {
	return "https://" + host + "/bkt/" + key +
		"?X-Amz-Credential=AKIAEXAMPLE%2F20261029%2Fauto%2Fs3%2Faws4_request&X-Amz-Signature=deadbeef"
}

func errLineURLErr(u string) error {
	return storeReadErr{&url.Error{Op: "Get", URL: u, Err: context.DeadlineExceeded}}
}

var errLineRefRe = regexp.MustCompile(`(?i)ref(/|%2f)[0-9a-f]{64}`)

// errLineLeaks names what s carries that a log line must not: a presigned query or a head key.
func errLineLeaks(s string) []string {
	var out []string
	if strings.Contains(strings.ToLower(s), "x-amz-") {
		out = append(out, "X-Amz-")
	}
	if strings.Contains(s, "?X-") {
		out = append(out, "?X-")
	}
	if m := errLineRefRe.FindString(s); m != "" {
		out = append(out, m)
	}
	return out
}

func TestLogSafeErrText(t *testing.T) {
	blob := errLineURLErr(errLinePresigned("store.example", "blob/"+errLineHex64))
	got := logSafeErrText(recoveredErr("fetch chunk 9707", blob))
	for _, want := range []string{"fetch chunk 9707", "context deadline exceeded", "https://store.example/bkt/blob/" + errLineHex64} {
		if !strings.Contains(got, want) {
			t.Errorf("blob URL: %q lost %q", got, want)
		}
	}
	if l := errLineLeaks(got); l != nil {
		t.Errorf("blob URL: %q still carries %v", got, l)
	}

	ref := errLineURLErr(errLinePresigned("store.example", "ref/"+errLineHex64))
	got = logSafeErrText(recoveredErr("fetch chunk 9707", ref))
	if !strings.Contains(got, "ref/<ref>") {
		t.Errorf("ref URL: %q does not show ref/<ref>", got)
	}
	if l := errLineLeaks(got); l != nil {
		t.Errorf("ref URL: %q still carries %v", got, l)
	}

	esc := errors.New("gateway /cap?op=read&ref=ref%2F" + errLineHex64 + ": HTTP 500 for ref%2F" + errLineHex64)
	if got := logSafeErrText(esc); errLineLeaks(got) != nil {
		t.Errorf("escaped ref: %q still carries %v", got, errLineLeaks(got))
	}

	plain := errors.New("notes blob 0123456789ab missing")
	if got := logSafeErrText(plain); got != plain.Error() {
		t.Errorf("an error with no URL changed: %q, want %q", got, plain.Error())
	}
	if got := logSafeErrText("corrupt chunk 3"); got != "corrupt chunk 3" {
		t.Errorf("a non-error panic value changed: %q", got)
	}
	if got := logSafeErrText(42); got != fmt.Sprint(42) {
		t.Errorf("a non-error panic value: %q, want %q", got, fmt.Sprint(42))
	}
}

// errCode and healErrText are what the media lines print; their fallback is the error's own text, so it has to be
// the redacted text. Their path branches stay as they were.
func TestErrLineErrCodeAndHealErrText(t *testing.T) {
	u := errLineURLErr(errLinePresigned("store.example", "ref/"+errLineHex64))
	for label, got := range map[string]string{
		"errCode":                 errCode(u),
		"errCode of a %v flatten": errCode(fmt.Errorf("fetch span [0,1): %v", u)),
		"healErrText":             healErrText(recoveredErr("chunk 1/1", u)),
	} {
		if l := errLineLeaks(got); l != nil {
			t.Errorf("%s: %q still carries %v", label, got, l)
		}
		if !strings.Contains(got, "context deadline exceeded") {
			t.Errorf("%s: %q lost the cause", label, got)
		}
	}
	if got := errCode(&fs.PathError{Op: "open", Path: "/data/media/0/x", Err: syscall.EACCES}); got != "permission denied" {
		t.Errorf("control: errCode of a path error = %q", got)
	}
	if got := errCode(errors.New("boom")); got != "boom" {
		t.Errorf("control: errCode(boom) = %q", got)
	}
	if got := errCode(nil); got != "none" {
		t.Errorf("control: errCode(nil) = %q", got)
	}
	if got := healErrText(&os.PathError{Op: "open", Path: "/p", Err: syscall.ENOENT}); got != "open: no such file or directory" {
		t.Errorf("control: healErrText of a path error = %q", got)
	}
}

// TestErrLineHelperProcess is not a test: it is the agent, re-executed from the test binary by
// TestErrLineCarriesNoPresignedQuery, so main()'s own recover prints the ERR: line and sets the exit code.
func TestErrLineHelperProcess(t *testing.T) {
	a := os.Getenv("NOWHERE_ERR_LINE_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

// The row's own case: a cap-mode sign-in whose presigned GET fails for good. The gateway hands out presigned-looking
// read caps on a port that refuses connections, so the first store read fails in transport after capGetRetryWindow.
func TestErrLineCarriesNoPresignedQuery(t *testing.T) {
	dead := deadStore(t)
	var served atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("/caps", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Op   string   `json:"op"`
			Refs []string `json:"refs"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		caps := map[string]string{}
		for _, ref := range req.Refs {
			caps[ref] = dead + "/bkt/" + ref +
				"?X-Amz-Credential=AKIAEXAMPLE%2F20261029%2Fauto%2Fs3%2Faws4_request&X-Amz-Signature=deadbeef"
			served.Add(1)
		}
		json.NewEncoder(w).Encode(map[string]any{"caps": caps, "ttl_seconds": 60})
	})
	gw := httptest.NewServer(mux)
	t.Cleanup(gw.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second) // a hang guard, not a bound
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestErrLineHelperProcess$", "-test.count=1")
	env := []string{
		"NOWHERE_ERR_LINE_HELPER=" + strings.Join([]string{"restore", "s3", "errlinered", "err line horse battery staple", t.TempDir()}, "\n"),
		"GATEWAY_URL=" + gw.URL,
		"S3_ACCESS_KEY=",
		"NOWHERE_STATE=" + t.TempDir(),
	}
	for _, kv := range os.Environ() {
		k := kv[:strings.IndexByte(kv+"=", '=')]
		switch k {
		case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS", "NOWHERE_STORE_GIVEUP", "NOWHERE_ERR_LINE_HELPER":
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = env
	b, err := cmd.CombinedOutput()
	out := string(b)
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("running the agent: %v\n%s", err, out)
		}
		code = ee.ExitCode()
	}
	if served.Load() == 0 {
		t.Fatalf("control: the gateway served no read cap, so no presigned GET was made\n%s", out)
	}
	errLine := ""
	for _, ln := range strings.Split(out, "\n") {
		if strings.HasPrefix(ln, "ERR:") {
			errLine = ln
		}
	}
	if errLine == "" {
		t.Errorf("no ERR: line\n%s", out)
	}
	t.Logf("the ERR: line: %s", errLine)
	if l := errLineLeaks(out); l != nil {
		t.Errorf("the agent's output carries %v\n%s", l, out)
	}
	if code != exitStoreUnreachable {
		t.Errorf("exit %d, want exitStoreUnreachable (%d): the exit code must still come from the raw value\n%s", code, exitStoreUnreachable, out)
	}
}

type errLineFailReader struct{ err error }

func (f errLineFailReader) Read([]byte) (int, error) { return 0, f.err }

type errLineZero struct{}

func (errLineZero) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}

// A restore whose chunk read fails mid-file: untarFrom's copy skip line prints the body read error. The tar reader
// keeps that error, so the next Next() panics with it: the raw chain must still reach exitStatus.
func TestUntarSkipLineCarriesNoPresignedQuery(t *testing.T) {
	var hb bytes.Buffer
	tw := tar.NewWriter(&hb)
	if err := tw.WriteHeader(&tar.Header{Name: "errline/a.bin", Mode: 0o600, Size: 4096, Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	tw.Flush()
	u := errLineURLErr(errLinePresigned("store.example", "blob/"+errLineHex64))
	rd := io.MultiReader(bytes.NewReader(hb.Bytes()[:512]), io.LimitReader(errLineZero{}, 10), errLineFailReader{u})
	dir := t.TempDir()
	var rec any
	out := captureStderr(t, func() { rec = panicOf(func() { untarFrom(dir, rd) }) })
	if !strings.Contains(out, "[restore] skip ") || !strings.Contains(out, "copy:") {
		t.Fatalf("no copy skip line\n%s", out)
	}
	if l := errLineLeaks(out); l != nil {
		t.Errorf("the copy skip line carries %v\n%s", l, out)
	}
	if !strings.Contains(out, "context deadline exceeded") {
		t.Errorf("the copy skip line lost the cause\n%s", out)
	}
	if strings.Contains(out, "a.bin") {
		t.Errorf("the copy skip line carries the entry's name\n%s", out)
	}
	e, _ := rec.(error)
	if rec == nil || !errors.Is(e, errStoreUnreachable) || exitStatus(rec) != exitStoreUnreachable {
		t.Errorf("the recovered value %v is not the raw store-unreachable chain", rec)
	}
}

// errLineBody is the source of fn in file: from its `func` line (or a `case` label's line) to the next top-level
// declaration (or the next case at the same depth).
func errLineBody(t *testing.T, file, fn string) []string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(b), "\n")
	isCase := strings.HasPrefix(fn, "case ")
	start, indent := -1, ""
	for i, ln := range lines {
		tr := strings.TrimLeft(ln, "\t")
		if isCase && strings.HasPrefix(tr, fn) {
			start, indent = i, ln[:len(ln)-len(tr)]
			break
		}
		if !isCase && (strings.HasPrefix(ln, "func "+fn+"(") || regexp.MustCompile(`^func \([^)]*\) `+regexp.QuoteMeta(fn)+`\(`).MatchString(ln)) {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("%s: %s not found", file, fn)
	}
	end := len(lines)
	for i := start + 1; i < len(lines); i++ {
		ln := lines[i]
		if isCase && (strings.HasPrefix(ln, indent+"case ") || strings.HasPrefix(ln, indent+"default:") || strings.HasPrefix(ln, indent[:max(len(indent)-1, 0)]+"}")) {
			end = i
			break
		}
		if !isCase && (strings.HasPrefix(ln, "func ") || strings.HasPrefix(ln, "}")) {
			end = i + 1
			break
		}
	}
	return lines[start:end]
}

// Every line that prints an error a store read can produce, held to logSafeErrText; the media lines held to
// errCode / healErrText, never logSafeErrText at the call site (an *fs.PathError's path would print unquoted). A head
// that starts "re:" is a regexp.
func TestErrLineSourcePins(t *testing.T) {
	for _, c := range []struct{ file, fn, head, want string }{
		{"main.go", "main", `"ERR:"`, "logSafeErrText("},
		{"main.go", "untarFrom", "restoreSkipLine(dir, hdr.Name, \"copy\"", "restoreSkipLine("},
		{"restore_skip_line.go", "restoreSkipLine", "errCode(", "errCode("},
		{"main.go", `case "restore-app":`, `re:"restore-app: %[sv]\\n"`, "logSafeErrText("},
		{"main.go", `case "ota-notes-get":`, `re:"ota-notes-get: %[sv]\\n"`, "logSafeErrText("},
		{"main.go", `case "build-warning-check", "build-warning-put":`, `"%s: %s: %`, "logSafeErrText("},
		{"main.go", `case "index-key-check", "index-key-put":`, `"%s: %s: %`, "logSafeErrText("},
		{"main.go", `case "export-manifest":`, `"export-manifest: profile %s -- %`, "logSafeErrText("},
		{"main.go", `case "wallet-push":`, `"wallet-push: refused -- %`, "logSafeErrText("},
		{"main.go", "retryPlanCarryGuarded", `plan carry retry: skipped (`, "logSafeErrText("},
		{"main.go", "dropBillPrevGuarded", `could not clear the carry record (`, "logSafeErrText("},
		{"main.go", "kickOtaRefresh", `[ota] refresh recovered: `, "logSafeErrText("},
		{"main.go", "finishStagedClaim", `the staged claim was not published (`, "logSafeErrText("},
		{"main.go", "promoteToStore", `[logind] promote vault %q: `, "logSafeErrText("},
		{"main.go", "maybePayRent", `re:\[logind\] pay-rent %q: %[sv]\\n`, "logSafeErrText("},
		{"main.go", "handleClaimMode", `re:\[logind\] claim -> %[sv]\\n`, "logSafeErrText("},
		{"main.go", "sealClaimedWallet", `wallet seal attempt %d/3 failed: `, "logSafeErrText("},
		{"main.go", "handleBackup", `manual backup PANIC recovered: `, "logSafeErrText("},
		{"main.go", "stageTelInboxForLiveSession", `(store read failed: `, "logSafeErrText("},
		{"main.go", "handleRollback", `[logind] rollback %q user %s FAILED: `, "logSafeErrText("},
		{"main.go", "rollbackGateReply", `[logind] rollback-gate %q FAILED: `, "logSafeErrText("},
		{"billing.go", "rebindPlanReporting", `[agent] plan carry: skipped (`, "logSafeErrText("},
		{"release_gen.go", "relGenAtRestore", `release generation not checked (`, "logSafeErrText("},
		{"snapshot_delete.go", "handleDeleteSnapshot", `snapshot delete %q user %s FAILED: `, "logSafeErrText("},
		{"ota_mandatory.go", "refreshOtaMandatory", `[ota] release metadata for %s not used: `, "logSafeErrText("},
		{"build_warning_fetch.go", "fetchBuildWarning", `[build-warning] not fetched: `, "logSafeErrText("},
		{"logout_wallet.go", "sealLogoutWalletAndDrop", `NOT published, kept (`, "logSafeErrText("},
		{"scope_rekey_job.go", "largeScopeRekeyStep", `progress record unreadable (`, "logSafeErrText("},
		{"scope_rekey_job.go", "rekeyOnce", `"[logind] rekey %s: %`, "logSafeErrText("},
		{"se_tie.go", "sessionTie", `not re-keyed: `, "logSafeErrText("},
		{"se_tie.go", "handleSETie", `"[logind] %s failed: %`, "logSafeErrText("},
		{"end_unsaved.go", "handleEndUnsaved", `could not be saved first (`, "logSafeErrText("},
		{"end_unsaved.go", "handleRestartUnsaved", `could not be saved first (`, "logSafeErrText("},
		{"mediafs.go", "", `seed fetch failed: `, "errCode("},
		{"mediafs.go", "", `"mediad: %v\n"`, "errCode("},
		{"media_server.go", "", `fetch failed, left deferred: `, "errCode("},
		{"media_server.go", "", `STOPPED at chunk %d/%d: `, "errCode("},
		{"media_span.go", "", `SKIPPED (%v)`, "errCode("},
		{"media_defer_sync.go", "", `SKIPPED (%v)`, "errCode("},
		{"media_heal.go", "", `stays deferred: `, "healErrText("},
	} {
		var body []string
		if c.fn == "" {
			b, err := os.ReadFile(c.file)
			if err != nil {
				t.Fatal(err)
			}
			body = strings.Split(string(b), "\n")
		} else {
			body = errLineBody(t, c.file, c.fn)
		}
		var hits []string
		match := func(ln string) bool { return strings.Contains(ln, c.head) }
		if re, ok := strings.CutPrefix(c.head, "re:"); ok {
			match = regexp.MustCompile(re).MatchString
		}
		for _, ln := range body {
			if match(ln) {
				hits = append(hits, ln)
			}
		}
		if len(hits) == 0 || (c.fn != "" && len(hits) != 1) {
			t.Errorf("%s %s: %d lines hold %q, want 1", c.file, c.fn, len(hits), c.head)
			continue
		}
		for _, ln := range hits {
			if !strings.Contains(ln, c.want) {
				t.Errorf("%s %s: the line does not print through %s\n%s", c.file, c.fn, c.want, ln)
			}
			if c.want != "logSafeErrText(" && strings.Contains(ln, "logSafeErrText(") {
				t.Errorf("%s: a media line prints logSafeErrText at the call site, which prints a path error's path unquoted\n%s", c.file, ln)
			}
		}
	}
	// The helpers' fallback is the redacted text, never the raw one.
	for _, h := range []struct{ file, fn string }{{"incremental_seal.go", "errCode"}, {"media_heal.go", "healErrText"}} {
		body := strings.Join(errLineBody(t, h.file, h.fn), "\n")
		if !strings.Contains(body, "return logSafeErrText(err)") || strings.Contains(body, "return err.Error()") {
			t.Errorf("%s %s: the fallback does not return logSafeErrText(err)\n%s", h.file, h.fn, body)
		}
	}
}
