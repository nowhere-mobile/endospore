package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
)

// End-to-end shuttle test: the daemon side runs openCTAPNFC + cbor over a real nfcShuttle, while a goroutine
// plays the CHOOSER -- reading "APDU <hex>" lines and answering "RESP <hex>" by transceiving against the mock
// ISO-DEP applet. Proves the socket line protocol + the APDU framing/61xx chaining work over the wire.
func TestNFCShuttleRoundTrip(t *testing.T) {
	daemonConn, chooserConn := net.Pipe()
	defer daemonConn.Close()
	defer chooserConn.Close()

	respBody := []byte{0xa1, 0x01, 0x02}
	applet := &mockApplet{selectSW: 0x9000, respFull: append([]byte{0x00}, respBody...), chunkSize: 2} // force 61xx chaining

	go func() {
		br := bufio.NewReader(chooserConn)
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "APDU ") {
				continue
			}
			apdu, err := hex.DecodeString(strings.TrimSpace(line[len("APDU "):]))
			if err != nil {
				fmt.Fprintf(chooserConn, "NFCERR bad apdu hex\n")
				continue
			}
			resp, err := applet.transceive(apdu)
			if err != nil {
				fmt.Fprintf(chooserConn, "NFCERR %v\n", err)
				continue
			}
			fmt.Fprintf(chooserConn, "RESP %x\n", resp)
		}
	}()

	sh := &nfcShuttle{conn: daemonConn, r: bufio.NewReader(daemonConn)}
	n, err := openCTAPNFC(sh)
	if err != nil {
		t.Fatalf("openCTAPNFC over shuttle: %v", err)
	}
	status, body, err := n.cbor(ctapGetAssertion, []byte{0x11, 0x22})
	if err != nil {
		t.Fatalf("cbor over shuttle: %v", err)
	}
	if status != 0x00 {
		t.Fatalf("status=0x%02x want 0x00", status)
	}
	if !bytes.Equal(body, respBody) {
		t.Fatalf("body=% x want % x", body, respBody)
	}
	if applet.lastCmd != ctapGetAssertion || !bytes.Equal(applet.lastParams, []byte{0x11, 0x22}) {
		t.Fatalf("applet saw cmd 0x%02x params % x", applet.lastCmd, applet.lastParams)
	}
}

// A transceive failure reported by the chooser ("NFCERR ...") surfaces as an error, not a hang or a bad parse.
func TestNFCShuttleError(t *testing.T) {
	daemonConn, chooserConn := net.Pipe()
	defer daemonConn.Close()
	defer chooserConn.Close()
	go func() {
		br := bufio.NewReader(chooserConn)
		if _, err := br.ReadString('\n'); err != nil { // consume the first APDU (the SELECT)
			return
		}
		fmt.Fprintf(chooserConn, "NFCERR tag lost\n")
	}()
	sh := &nfcShuttle{conn: daemonConn, r: bufio.NewReader(daemonConn)}
	if _, err := openCTAPNFC(sh); err == nil {
		t.Fatal("openCTAPNFC ignored an NFCERR from the chooser")
	}
}

// A DEAD LINK must end the whole assert, not walk the remaining slots. Each extra slot costs a full
// per-exchange timeout against a tag that has already stopped answering, and on lynx 2026-08-25 that
// second attempt was measured hanging 30s -- the entire user-visible "hold still ... couldn't sign in".
// The counter is the point of the test: ONE failed exchange, not one per slot.
func TestAssertOverNFCStopsAtTheFirstDeadLink(t *testing.T) {
	daemonConn, chooserConn := net.Pipe()
	defer daemonConn.Close()
	defer chooserConn.Close()

	var mu sync.Mutex
	apdus := 0
	go func() {
		br := bufio.NewReader(chooserConn)
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			if !strings.HasPrefix(strings.TrimSpace(line), "APDU ") {
				continue
			}
			mu.Lock()
			apdus++
			n := apdus
			mu.Unlock()
			if n == 1 {
				fmt.Fprintf(chooserConn, "RESP 9000\n") // SELECT succeeds, as it does on a real brownout
				continue
			}
			fmt.Fprintf(chooserConn, "NFCERR tag lost\n") // then the link dies mid-ceremony
		}
	}()

	sh := &nfcShuttle{conn: daemonConn, r: bufio.NewReader(daemonConn)}
	salt := base64.StdEncoding.EncodeToString(make([]byte, 32))
	slots := []fido2SlotInfo{
		{CredID: base64.StdEncoding.EncodeToString([]byte("cred-one")), Salt: salt},
		{CredID: base64.StdEncoding.EncodeToString([]byte("cred-two")), Salt: salt},
		{CredID: base64.StdEncoding.EncodeToString([]byte("cred-three")), Salt: salt},
	}
	if _, err := fido2AssertOverNFC(sh, slots); err == nil {
		t.Fatal("a dead link must fail the assert")
	}
	mu.Lock()
	defer mu.Unlock()
	// 1 SELECT + exactly ONE failed exchange. More means the loop kept talking to a dead tag.
	if apdus > 2 {
		t.Fatalf("kept talking to a dead tag: %d APDUs sent, want 2 (the loop walked the other slots)", apdus)
	}
}
