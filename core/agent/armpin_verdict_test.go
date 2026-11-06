package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261031-05: ARM-PIN answers PINSET only for an `armed` marker. roamd's armcred writes the verdict into
// .armcred.<uid> (`armed` | `notarmed`); a marker with any other content reads PINNOTARMED and no marker PINQUEUED.
// The chooser counts only PINSET, so the other two take its DPM never-lock-out arm and keep the screen-off retry.

// armPinDrive runs one ARM-PIN round trip against dest and returns the reply and how many times the kick ran.
func armPinDrive(t *testing.T, dest string) (string, int) {
	t.Helper()
	var mu sync.Mutex
	kicks := 0
	kicked := make(chan struct{}, 4)
	old := armPinKick
	armPinKick = func(d, nm, cred, uid, ps string) {
		mu.Lock()
		kicks++
		mu.Unlock()
		kicked <- struct{}{}
	}
	defer func() { armPinKick = old }()

	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { handleLogin(srv, dest); close(done) }()
	cli.SetDeadline(time.Now().Add(5 * time.Second))
	cli.Write([]byte("ARM-PIN\n"))
	buf := make([]byte, 64)
	n, _ := cli.Read(buf)
	cli.Close()
	<-done
	select {
	case <-kicked:
	case <-time.After(2 * time.Second):
	}
	time.Sleep(50 * time.Millisecond) // a second, wrong kick would land here
	mu.Lock()
	defer mu.Unlock()
	return strings.TrimSpace(string(buf[:n])), kicks
}

func TestArmPinVerdict(t *testing.T) {
	for _, c := range []struct {
		label  string
		marker *string
		want   string
	}{
		{"armed", ptr("armed\n"), "PINSET"},
		{"armed without newline", ptr("armed"), "PINSET"},
		{"notarmed", ptr("notarmed\n"), "PINNOTARMED"},
		{"empty marker", ptr(""), "PINNOTARMED"},
		{"no marker", nil, "PINQUEUED"},
	} {
		dest := t.TempDir()
		if err := writeRoamSession(dest, "armpin-verdict-"+strings.ReplaceAll(c.label, " ", "-"), "pass-armpin-1", "11", "", true); err != nil {
			t.Fatal(err)
		}
		if c.marker != nil {
			if err := os.WriteFile(filepath.Join(dest, ".armcred.11"), []byte(*c.marker), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		got, kicks := armPinDrive(t, dest)
		if got != c.want {
			t.Errorf("%s: ARM-PIN answered %q, want %q", c.label, got, c.want)
		}
		if kicks != 1 {
			t.Errorf("%s: armcred kicked %d times, want 1", c.label, kicks)
		}
	}
}

func TestArmPinNoSessionIsFallbackAndNoKick(t *testing.T) {
	got, kicks := armPinDrive(t, t.TempDir())
	if got != "FALLBACK" || kicks != 0 {
		t.Errorf("no session: reply %q kicks %d, want FALLBACK and 0", got, kicks)
	}
}

func ptr(s string) *string { return &s }
