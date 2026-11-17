package main

// NWP-20261204-08: the login daemon republishes nowhere.gateway_url (NowherePush's gateway) whenever it changes
// GATEWAY_URL at run time -- a managed enrolment (applyManagedStore), discovery or set-gateway (applyGateway) -- with
// issueGatewayURL()'s value, so a push endpoint is minted on the gateway the agent uses, without a reboot.
// test-gateway-prop.sh --mutate convicts each assertion here.

import (
	"path/filepath"
	"strings"
	"testing"
)

// gatewayPropFixture gives a test its own conf, empty gateway env and S3_* env, and replaces publishGatewayProp
// with a recorder. onPublish (may be nil) runs inside the hook, before the value is recorded.
func gatewayPropFixture(t *testing.T, onPublish func()) *[]string {
	t.Helper()
	oldConf, oldPub := storeConfPath, publishGatewayProp
	oldClient, oldBucket := s3client, s3bucket
	storeConfPath = filepath.Join(t.TempDir(), "nowhere.conf")
	t.Cleanup(func() {
		storeConfPath, publishGatewayProp = oldConf, oldPub
		s3client, s3bucket = oldClient, oldBucket
	})
	// t.Setenv restores each variable after the test, also after the code under test wrote or unset it.
	for _, k := range []string{"GATEWAY_URL", "NOWHERE_GATEWAY_DEFAULT",
		"S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY"} {
		t.Setenv(k, "")
	}
	calls := &[]string{}
	publishGatewayProp = func(v string) error {
		if onPublish != nil {
			onPublish()
		}
		*calls = append(*calls, v)
		return nil
	}
	return calls
}

func wantGatewayPropCalls(t *testing.T, what string, got []string, want ...string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: %d setprop call(s) %q, want %d %q", what, len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%s: setprop call %d = %q, want %q", what, i, got[i], want[i])
		}
	}
}

func TestGatewayPropRepublishedOnManagedEnrol(t *testing.T) {
	calls := gatewayPropFixture(t, nil)
	const gw = "https://api-beta.nowhere.mobile"
	if err := applyManagedStore(gw); err != nil {
		t.Fatalf("applyManagedStore: %v", err)
	}
	wantGatewayPropCalls(t, "managed enrolment", *calls, gw)
}

func TestGatewayPropRepublishedOnDiscovery(t *testing.T) {
	calls := gatewayPropFixture(t, nil)
	applyGateway("https://gw-a.example")
	wantGatewayPropCalls(t, "discovery", *calls, "https://gw-a.example")
	*calls = nil
	applyGateway("https://gw-b.example/")
	wantGatewayPropCalls(t, "discovery, trailing slash", *calls, "https://gw-b.example")
}

func TestGatewayPropClearFallsBackToDefault(t *testing.T) {
	calls := gatewayPropFixture(t, nil)
	const def = "https://gw-default.example"
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", def)
	applyGateway("")
	wantGatewayPropCalls(t, "set-gateway clear", *calls, def)
}

func TestGatewayPropSkipsEmptyAndTooLong(t *testing.T) {
	calls := gatewayPropFixture(t, nil)
	applyGateway("")
	wantGatewayPropCalls(t, "both unset", *calls)

	long := "https://" + strings.Repeat("a", 84)
	if len(long) != 92 {
		t.Fatalf("fixture: len(long) = %d, want 92", len(long))
	}
	applyGateway(long)
	wantGatewayPropCalls(t, "92-byte value", *calls)

	fits := long[:91]
	if len(fits) != 91 {
		t.Fatalf("fixture: len(fits) = %d, want 91", len(fits))
	}
	applyGateway(fits)
	wantGatewayPropCalls(t, "91-byte value", *calls, fits)
}

func TestGatewayPropNotUnderTheStoreLock(t *testing.T) {
	underLock := false
	calls := gatewayPropFixture(t, func() {
		if s3InitMu.TryLock() {
			s3InitMu.Unlock()
		} else {
			underLock = true
		}
	})
	const gw = "https://api-beta.nowhere.mobile"
	if err := applyManagedStore(gw); err != nil {
		t.Fatalf("applyManagedStore: %v", err)
	}
	wantGatewayPropCalls(t, "managed enrolment", *calls, gw)
	if underLock {
		t.Fatal("publishGatewayProp ran while s3InitMu was held: setprop must run after the unlock")
	}
}

func TestGatewayPropName(t *testing.T) {
	// The name NowherePush's PushService.GATEWAY_PROP reads and property_contexts labels (NWP-20261203-13).
	if gatewayProp != "nowhere.gateway_url" {
		t.Fatalf("gatewayProp = %q, want %q", gatewayProp, "nowhere.gateway_url")
	}
}
