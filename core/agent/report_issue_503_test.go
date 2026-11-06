package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// NWP-20261112-04 (dn-1101 #2): the gateway answers /support 503 for three reasons, and only one of them means
// support is switched off. A full or unreadable intake (supportAdmit, NWC-20261107-03) is a failed send, so the
// reporters must get a reply their default arm shows as "Couldn't send the report (ERR 503).", not ERR-DISABLED.

// report503Reply runs one gate-scope REPORT-ISSUE against a gateway that answers /support with status and body,
// and returns the daemon's one-line reply.
func report503Reply(t *testing.T, status int, ctype, body string) string {
	t.Helper()
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/support" {
			t.Errorf("gateway got %s %s, want POST /support", r.Method, r.URL.Path)
		}
		_, _ = io.Copy(io.Discard, r.Body)
		if ctype != "" {
			w.Header().Set("Content-Type", ctype)
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	defer gw.Close()
	t.Setenv("NOWHERE_DIR", t.TempDir())
	t.Setenv("GATEWAY_URL", gw.URL)
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")

	srv, cli := net.Pipe()
	defer cli.Close()
	go func() { handleReportIssue(srv, t.TempDir(), `{"note":"t","gate":true}`); srv.Close() }()
	b, err := io.ReadAll(cli)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestReportIssue503NotConfiguredIsDisabled(t *testing.T) {
	if got := report503Reply(t, http.StatusServiceUnavailable, "application/json", `{"error":"support intake not configured"}`); got != "ERR-DISABLED" {
		t.Errorf("503 support intake not configured: reply %q, want ERR-DISABLED (support is switched off)", got)
	}
}

func TestReportIssue503IntakeFullIsAFailedSend(t *testing.T) {
	if got := report503Reply(t, http.StatusServiceUnavailable, "application/json", `{"error":"support intake full"}`); got != "ERR 503" {
		t.Errorf("503 support intake full: reply %q, want ERR 503 (the report was not sent; support is not off)", got)
	}
}

func TestReportIssue503IntakeUnavailableIsAFailedSend(t *testing.T) {
	if got := report503Reply(t, http.StatusServiceUnavailable, "application/json", `{"error":"support intake unavailable"}`); got != "ERR 503" {
		t.Errorf("503 support intake unavailable: reply %q, want ERR 503 (the report was not sent; support is not off)", got)
	}
}

func TestReportIssue503ProxyBodyIsAFailedSend(t *testing.T) {
	page := "<html><body><h1>503 Service Unavailable</h1>support intake not configured upstream</body></html>"
	if got := report503Reply(t, http.StatusServiceUnavailable, "text/html", page); got != "ERR 503" {
		t.Errorf("503 with a proxy's HTML page: reply %q, want ERR 503 (only the gateway's exact refusal means switched off)", got)
	}
}

func TestReportIssue503OKStillFilesTicket(t *testing.T) {
	if got := report503Reply(t, http.StatusOK, "application/json", `{"ticket":"NW-0123456789ab"}`); got != "OK NW-0123456789ab" {
		t.Errorf("200 with a ticket: reply %q, want OK NW-0123456789ab", got)
	}
}

func TestReportIssue503TooBigUnchanged(t *testing.T) {
	if got := report503Reply(t, http.StatusRequestEntityTooLarge, "application/json", `{"error":"report too large"}`); got != "ERR-TOOBIG" {
		t.Errorf("413: reply %q, want ERR-TOOBIG", got)
	}
}
