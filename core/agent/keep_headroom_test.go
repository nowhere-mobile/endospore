package main

import (
	"bufio"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// KEEP-HEADROOM (Q025 [BA], decided 2026-10-20): turning on Keep counts the app's own size against the plan.
// keepHeadroomReply is session-free and takes storedAppsCached's answer as parameters, so no case here waits on
// that cache's async first call; the handler cases are only the paths that answer before it.

const keepHrPass = "horse battery staple correct"

// keepHrEst is the discounted size the gate charges for an installed set of b bytes.
func keepHrEst(b int64) int64 { return b - b/4 }

// keepHrSetup makes a profile named name and a gateway whose coverage is the profile's used bytes plus slack.
func keepHrSetup(t *testing.T, name string, slack int64) (g *gatewayClient, base, wallet string, total int64) {
	t.Helper()
	base = newHTTPStore(t)
	_, total = admGateProfile(t, base, name, keepHrPass, 64<<10, 64<<10)
	g, _ = admGateGateway(t, entitlementInfo{FreeBytes: total + slack, CoveredBytes: total + slack})
	return g, base, admGateWallet(t), total
}

func TestKeepHeadroomFitsAnswersTheDiscountedSum(t *testing.T) {
	const name = "keephr-fits"
	g, base, w, _ := keepHrSetup(t, name, 1<<30)
	got := keepHeadroomReply(g, base, name, keepHrPass, w, "org.example.a:4000 org.example.b:1003", nil, false, nil)
	if want := fmt.Sprintf("OK add=%d", (4000-1000)+(1003-250)); got != want {
		t.Errorf("reply %q, want %q", got, want)
	}
}

func TestKeepHeadroomRefusesWhenTheAddWouldPushOverThePlan(t *testing.T) {
	const name = "keephr-over"
	base := newHTTPStore(t)
	_, total := admGateProfile(t, base, name, keepHrPass, 64<<10, 64<<10)
	add := keepHrEst(40001) + keepHrEst(30003)
	covered := total + add/2
	if !(total < covered && covered < total+add) {
		t.Fatalf("total=%d covered=%d add=%d: need used < covered < used+add", total, covered, add)
	}
	g, _ := admGateGateway(t, entitlementInfo{FreeBytes: covered, CoveredBytes: covered})
	got := keepHeadroomReply(g, base, name, keepHrPass, admGateWallet(t), "org.example.a:40001 org.example.b:30003", nil, false, nil)
	if want := overPlanReply(total+add-covered, total, covered, add); got != want {
		t.Errorf("reply %q, want %q", got, want)
	}
}

func TestKeepHeadroomChargesOnlyTheGrowthOfAHeldApp(t *testing.T) {
	const name = "keephr-held"
	g, base, w, _ := keepHrSetup(t, name, 20000)
	for _, c := range []struct {
		stored int64
		want   string
	}{
		{25000, "OK add=5000"},
		{30000, "OK add=0"},
		{50000, "OK add=0"},
	} {
		got := keepHeadroomReply(g, base, name, keepHrPass, w, "org.example.held:40000", map[string]int64{"org.example.held": c.stored}, true, nil)
		if got != c.want {
			t.Errorf("stored %d: reply %q, want %q", c.stored, got, c.want)
		}
	}
}

func TestKeepHeadroomUnmeasuredChargesTheFullEstimate(t *testing.T) {
	stored := map[string]int64{"org.example.held": 25000}
	{
		const name = "keephr-unmeasured"
		g, base, w, _ := keepHrSetup(t, name, 40000)
		if got := keepHeadroomReply(g, base, name, keepHrPass, w, "org.example.held:40000", stored, false, nil); got != "OK add=30000" {
			t.Errorf("reply %q, want OK add=30000", got)
		}
	}
	const name = "keephr-unmeasured-over"
	g, base, w, total := keepHrSetup(t, name, 20000)
	got := keepHeadroomReply(g, base, name, keepHrPass, w, "org.example.held:40000", stored, false, nil)
	if want := overPlanReply(10000, total, total+20000, 30000); got != want {
		t.Errorf("reply %q, want %q", got, want)
	}
}

func TestKeepHeadroomRefusesABadPayload(t *testing.T) {
	const name = "keephr-arg"
	g, base, w, _ := keepHrSetup(t, name, 1<<40)
	var seventeen, sixteen []string
	for i := 0; i < 17; i++ {
		e := fmt.Sprintf("org.example.p%d:1", i)
		seventeen = append(seventeen, e)
		if i < 16 {
			sixteen = append(sixteen, e)
		}
	}
	bad := []string{"", "   ", strings.Join(seventeen, " "), "com..x:1", "1a.b:1", "nodot:1", "org.example.a",
		"org.example.a:", "org.example.a:-1", "org.example.a:+5", "org.example.a:1.5", "org.example.a:0x10",
		"org.example.a:17179869185", "org.example.a:1 org.example.a:2"}
	for _, p := range bad {
		if got := keepHeadroomReply(g, base, name, keepHrPass, w, p, nil, false, nil); got != "ERR-ARG" {
			t.Errorf("payload %q: reply %q, want ERR-ARG", p, got)
		}
	}
	for _, p := range []string{"org.example.a:17179869184", "org.example.a:0", strings.Join(sixteen, " ")} {
		if got := keepHeadroomReply(g, base, name, keepHrPass, w, p, nil, false, nil); !strings.HasPrefix(got, "OK add=") {
			t.Errorf("payload %q: reply %q, want OK add=...", p, got)
		}
	}
}

// keepHrAsk runs handleKeepHeadroom over a pipe with a one-entry payload and returns its one-line answer.
func keepHrAsk(t *testing.T, dest string) string {
	t.Helper()
	cli, srv := net.Pipe()
	t.Cleanup(func() { cli.Close(); srv.Close() })
	cli.SetDeadline(time.Now().Add(10 * time.Second))
	done := make(chan struct{})
	go func() {
		defer close(done)
		handleKeepHeadroom(srv, bufio.NewReader(srv), dest)
	}()
	fmt.Fprint(cli, "org.example.a:1\n")
	line, _ := bufio.NewReader(cli).ReadString('\n')
	<-done
	return strings.TrimRight(line, "\n")
}

func TestKeepHeadroomHandlerAnswersBeforeTheStoredAppsRead(t *testing.T) {
	t.Run("no session", func(t *testing.T) {
		if got := keepHrAsk(t, t.TempDir()); got != "NONE" {
			t.Errorf("reply %q, want NONE", got)
		}
	})
	t.Run("no gateway", func(t *testing.T) {
		dest := t.TempDir()
		if err := writeRoamSession(dest, "keephr-nogw", "pw", "10", "", true); err != nil {
			t.Fatal(err)
		}
		t.Setenv("GATEWAY_URL", "")
		if got := keepHrAsk(t, dest); got != "NONE" {
			t.Errorf("reply %q, want NONE", got)
		}
	})
	t.Run("local", func(t *testing.T) {
		dest := t.TempDir()
		if err := writeRoamSession(dest, "keephr-local", "pw", "10", "", true); err != nil {
			t.Fatal(err)
		}
		markLocalSession(dest)
		t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
		if got := keepHrAsk(t, dest); got != "LOCAL" {
			t.Errorf("reply %q, want LOCAL", got)
		}
	})
}
