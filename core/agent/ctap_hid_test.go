package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// NWP-20261023-01: the CTAPHID framing (ctap_hid.go) driven over a fake hidraw, a SOCK_SEQPACKET pair, so every write
// keeps its record boundary and its real length. The fake key models usbhid's output path: a record whose first byte is
// 0x00 loses it, and what remains must be exactly one 64-byte report; a bare 64-byte record whose first byte is not 0x00
// is delivered as it is (which is why a key whose channel id starts with a non-zero byte worked before the report-number
// byte was written). Anything else is a FRAMING FAULT. test-ctap-hid.sh --mutate breaks each rule in ctap_hid.go.

const hidHighCID = 0xA1B2C3D4

type hidRaw struct {
	n     int
	first byte
}

// hidPair returns the two ends of a fake hidraw; both close at test end. A goroutine reading either end must have
// returned before then (hidHost's cleanup, the send-size drain's marker): once an fd is closed its number is reused by
// the next test's socket pair, and a reader that outlives its test serves that one instead (NWP-20261021-30).
func hidPair(t *testing.T) (a, b int) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET, 0)
	if err != nil {
		t.Fatalf("socketpair: %v", err)
	}
	t.Cleanup(func() { unix.Close(fds[0]); unix.Close(fds[1]) })
	return fds[0], fds[1]
}

// hidUsbhid is usbhid's output path: the report the key receives for one write, or false for a framing fault.
func hidUsbhid(rec []byte) ([]byte, bool) {
	switch {
	case len(rec) == hidReportSize+1 && rec[0] == 0:
		return rec[1:], true
	case len(rec) == hidReportSize && rec[0] != 0:
		return rec, true
	}
	return nil, false
}

func hidInitPkt(cid uint32, cmd byte, bcnt int, data []byte) []byte {
	p := make([]byte, hidReportSize)
	binary.BigEndian.PutUint32(p[0:4], cid)
	p[4] = cmd
	binary.BigEndian.PutUint16(p[5:7], uint16(bcnt))
	copy(p[7:], data)
	return p
}

func hidContPkt(cid uint32, seq byte, data []byte) []byte {
	p := make([]byte, hidReportSize)
	binary.BigEndian.PutUint32(p[0:4], cid)
	p[4] = seq
	copy(p[5:], data)
	return p
}

// hidFrame is a test-local CTAPHID framer, so the fake never relies on the code under test to build an answer.
func hidFrame(cid uint32, cmd byte, payload []byte) [][]byte {
	first := payload
	if len(first) > 57 {
		first = first[:57]
	}
	out := [][]byte{hidInitPkt(cid, cmd, len(payload), first)}
	rest := payload[len(first):]
	for seq := byte(0); len(rest) > 0; seq++ {
		n := len(rest)
		if n > 59 {
			n = 59
		}
		out = append(out, hidContPkt(cid, seq, rest[:n]))
		rest = rest[n:]
	}
	return out
}

func hidFill(n int, v byte) []byte { return bytes.Repeat([]byte{v}, n) }

type hidMsg struct {
	cid     uint32
	cmd     byte
	bcnt    int
	data    []byte
	nextSeq byte
}

// hidFake is the key end of the fake hidraw.
type hidFake struct {
	t       *testing.T
	fd      int
	cid     uint32                    // the channel id allocated at INIT
	initAns func(nonce []byte) []byte // nil: the nonce, the cid and 02 01 00 00 00
	answer  func(req []byte) [][]byte // raw 64-byte records sent after a CBOR request
	peer    int                       // the host end
	stop    chan struct{}             // closed by hidHost's cleanup: the reader returns at its next wait
	done    chan struct{}             // closed when the reader has returned
	ino     [2]uint64                 // the inodes of fd and peer when the reader started
	late    bool                      // the reader returned after fd or peer stopped naming its socket

	mu      sync.Mutex
	raw     []hidRaw
	framing []string
	reqf    []string
	cids    []uint32
	seqs    []byte
	reqs    [][]byte
}

// wait polls f.fd (non-blocking, hidHost) until it is ready for events, or returns false once stop is closed. The
// reader never sits in read(2) or write(2): closing an fd does not wake a call blocked on it, so such a reader would
// outlive its test.
func (f *hidFake) wait(events int16) bool {
	pfd := []unix.PollFd{{Fd: int32(f.fd), Events: events}}
	for {
		select {
		case <-f.stop:
			return false
		default:
		}
		n, err := unix.Poll(pfd, 10)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return false
		}
		if n > 0 {
			return true
		}
	}
}

func (f *hidFake) write(recs ...[]byte) {
	for _, r := range recs {
		for {
			_, err := unix.Write(f.fd, r)
			if err == unix.EAGAIN {
				if !f.wait(unix.POLLOUT) {
					return
				}
				continue
			}
			if err != nil {
				return
			}
			break
		}
	}
}

func (f *hidFake) errFrame(code byte) {
	cid := f.cid
	if cid == 0 {
		cid = hidBroadcast
	}
	f.write(hidFrame(cid, ctaphidError, []byte{code})...)
}

func (f *hidFake) start() {
	f.stop, f.done = make(chan struct{}), make(chan struct{})
	for i, fd := range []int{f.fd, f.peer} {
		var st unix.Stat_t
		if err := unix.Fstat(fd, &st); err != nil {
			f.t.Fatalf("fstat: %v", err)
		}
		f.ino[i] = st.Ino
	}
	go func() {
		defer close(f.done)
		defer func() { // read after <-f.done
			for i, fd := range []int{f.fd, f.peer} {
				var st unix.Stat_t
				if unix.Fstat(fd, &st) != nil || st.Ino != f.ino[i] {
					f.late = true
				}
			}
		}()
		var rec [128]byte
		var cur *hidMsg
		dead := false
		for {
			if !f.wait(unix.POLLIN) {
				return
			}
			n, err := unix.Read(f.fd, rec[:])
			if err == unix.EAGAIN {
				continue
			}
			if err != nil || n <= 0 {
				return
			}
			f.t.Logf("raw record: %d bytes, first 0x%02x", n, rec[0])
			f.mu.Lock()
			f.raw = append(f.raw, hidRaw{n, rec[0]})
			f.mu.Unlock()
			if dead {
				continue
			}
			rep, ok := hidUsbhid(rec[:n])
			if !ok {
				f.mu.Lock()
				f.framing = append(f.framing, fmt.Sprintf("%d-byte record, first byte 0x%02x", n, rec[0]))
				f.mu.Unlock()
				f.errFrame(0x03)
				dead = true
				continue
			}
			fault := func(msg string) {
				f.mu.Lock()
				f.reqf = append(f.reqf, msg)
				f.mu.Unlock()
				f.errFrame(0x04)
				dead = true
			}
			cid := binary.BigEndian.Uint32(rep[0:4])
			if cur == nil {
				if rep[4]&0x80 == 0 {
					fault("a continuation with no message in progress")
					continue
				}
				bcnt := int(binary.BigEndian.Uint16(rep[5:7]))
				cur = &hidMsg{cid: cid, cmd: rep[4], bcnt: bcnt}
				take := bcnt
				if take > 57 {
					take = 57
				}
				cur.data = append(cur.data, rep[7:7+take]...)
				if !bytes.Equal(rep[7+take:], make([]byte, hidReportSize-7-take)) {
					fault("non-zero padding in the init packet")
					continue
				}
			} else {
				if cid != cur.cid || rep[4] != cur.nextSeq {
					fault(fmt.Sprintf("continuation SEQ %d, expected %d", rep[4], cur.nextSeq))
					continue
				}
				f.mu.Lock()
				f.seqs = append(f.seqs, rep[4])
				f.mu.Unlock()
				cur.nextSeq++
				take := cur.bcnt - len(cur.data)
				if take > 59 {
					take = 59
				}
				cur.data = append(cur.data, rep[5:5+take]...)
				if !bytes.Equal(rep[5+take:], make([]byte, hidReportSize-5-take)) {
					fault("non-zero padding in a continuation")
					continue
				}
			}
			if cur.cmd == ctaphidCBOR {
				f.mu.Lock()
				f.cids = append(f.cids, cid)
				f.mu.Unlock()
			}
			if len(cur.data) < cur.bcnt {
				continue
			}
			m := cur
			cur = nil
			switch m.cmd {
			case ctaphidInit:
				ans := f.initAns
				if ans == nil {
					ans = func(nonce []byte) []byte {
						out := append([]byte(nil), nonce...)
						out = binary.BigEndian.AppendUint32(out, f.cid)
						return append(out, 0x02, 0x01, 0x00, 0x00, 0x00)
					}
				}
				f.write(hidFrame(hidBroadcast, ctaphidInit, ans(m.data))...)
			case ctaphidCBOR:
				f.mu.Lock()
				f.reqs = append(f.reqs, m.data)
				f.mu.Unlock()
				if f.answer != nil { // nil: an empty answer, as hidHost says
					f.write(f.answer(m.data)...)
				}
			}
		}
	}()
}

// flooding reports whether the reader has taken a CBOR request, so its answer is being written.
func (f *hidFake) flooding() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.reqs) > 0
}

func (f *hidFake) snapshot() (raw []hidRaw, framing, reqf []string, cids []uint32, seqs []byte, reqs [][]byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]hidRaw(nil), f.raw...), append([]string(nil), f.framing...), append([]string(nil), f.reqf...),
		append([]uint32(nil), f.cids...), append([]byte(nil), f.seqs...), append([][]byte(nil), f.reqs...)
}

// hidHost wires a ctapHID to a running fake key allocating cid; a nil answer is an empty one. Its cleanup is registered
// after hidPair's, so it runs first: the fake's reader has returned before either fd is closed.
func hidHost(t *testing.T, cid uint32, answer func(req []byte) [][]byte, initAns func([]byte) []byte) (*ctapHID, *hidFake) {
	t.Helper()
	a, b := hidPair(t)
	if err := unix.SetNonblock(b, true); err != nil {
		t.Fatalf("nonblock: %v", err)
	}
	f := &hidFake{t: t, fd: b, peer: a, cid: cid, initAns: initAns, answer: answer}
	f.start()
	t.Cleanup(func() {
		close(f.stop)
		select {
		case <-f.done:
		case <-time.After(10 * time.Second):
			t.Errorf("the fake key's reader did not return within 10s of its test's end")
		}
	})
	return &ctapHID{fd: a, cid: hidBroadcast}, f
}

func hidRoundTrip(t *testing.T, cid uint32, rawShape bool) {
	params := hidFill(149, 0x5A)
	resp := append([]byte{0x00}, hidFill(299, 0xC3)...)
	h, f := hidHost(t, cid, func([]byte) [][]byte { return hidFrame(cid, ctaphidCBOR, resp) }, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	if h.cid != cid {
		t.Fatalf("allocated cid 0x%08x, want 0x%08x", h.cid, cid)
	}
	status, body, err := h.cbor(0x01, params)
	if err != nil {
		t.Fatalf("cbor: %v", err)
	}
	raw, framing, reqf, cids, seqs, reqs := f.snapshot()
	if len(framing) != 0 {
		t.Errorf("framing fault(s): %v", framing)
	}
	if len(reqf) != 0 {
		t.Errorf("request fault(s): %v", reqf)
	}
	if rawShape {
		for i, r := range raw {
			if r.n != hidReportSize+1 || r.first != 0x00 {
				t.Errorf("raw record %d: %d bytes, first 0x%02x; want 65 bytes behind a 0x00 report number", i, r.n, r.first)
			}
		}
		if len(raw) != 4 { // INIT, then the CBOR init packet and 2 continuations
			t.Errorf("%d raw records, want 4", len(raw))
		}
		for _, c := range cids {
			if c != cid {
				t.Errorf("the key decoded cid 0x%08x on a CBOR packet, want 0x%08x", c, cid)
			}
		}
	}
	if len(reqs) != 1 || !bytes.Equal(reqs[0], append([]byte{0x01}, params...)) {
		t.Errorf("the request did not reassemble byte for byte: %x", reqs)
	}
	if !bytes.Equal(seqs, []byte{0, 1}) {
		t.Errorf("request continuation SEQs %v, want [0 1]", seqs)
	}
	if status != 0 || !bytes.Equal(body, resp[1:]) {
		t.Errorf("status %d, %d-byte body; want status 0 and the %d-byte body cut to its count", status, len(body), len(resp)-1)
	}
}

// (a) A key whose channel id begins with 0x00: the first CBOR packet reaches it only behind a report-number byte.
func TestCtapHID_LowCIDRoundTrip(t *testing.T) { hidRoundTrip(t, 0x00000001, true) }

// (b) A key that worked before: the 65-byte write must not break it. Passes on the code that had no report-number byte.
func TestCtapHID_HighCIDRoundTrip(t *testing.T) { hidRoundTrip(t, hidHighCID, false) }

// (c) KEEPALIVE frames and a report on another channel are skipped; the real answer is returned.
func TestCtapHID_SkipsKeepaliveAndOtherChannel(t *testing.T) {
	cid := uint32(hidHighCID)
	h, _ := hidHost(t, cid, func([]byte) [][]byte {
		return append([][]byte{
			hidInitPkt(cid, ctaphidKeepAlv, 1, []byte{0x02}),
			hidInitPkt(cid, ctaphidKeepAlv, 1, []byte{0x02}),
			hidInitPkt(0x55, ctaphidCBOR, 3, []byte{0x00, 0xEE, 0xEE}),
		}, hidFrame(cid, ctaphidCBOR, []byte{0x00, 0x01, 0x02, 0x03})...)
	}, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	status, body, err := h.cbor(0x01, nil)
	if err != nil || status != 0 || !bytes.Equal(body, []byte{1, 2, 3}) {
		t.Fatalf("status %d, body %x, err %v; want status 0, body 010203", status, body, err)
	}
}

// (d) A broken continuation sequence is an error, never data: the packets that follow would complete the message.
func TestCtapHID_ContinuationOrder(t *testing.T) {
	cid := uint32(hidHighCID)
	first := hidInitPkt(cid, ctaphidCBOR, 57+3*59, hidFill(57, 0xAA))
	cont := func(seq byte) []byte { return hidContPkt(cid, seq, hidFill(59, 0xBB)) }
	cases := []struct {
		name string
		recs [][]byte
		want []string
	}{
		{"gap", [][]byte{first, cont(0), cont(2), cont(3)}, []string{"expected SEQ 1", "received 2"}},
		{"repeat", [][]byte{first, cont(0), cont(0), cont(1)}, []string{"SEQ", "received 0"}},
		{"interleaved", [][]byte{first, cont(0), hidInitPkt(cid, ctaphidCBOR, 5, hidFill(5, 0xCC)), cont(1), cont(2)},
			[]string{"a new message began before the last one ended"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, _ := hidHost(t, cid, func([]byte) [][]byte { return c.recs }, nil)
			if err := h.initChannel(); err != nil {
				t.Fatalf("initChannel: %v", err)
			}
			status, body, err := h.cbor(0x01, nil)
			if err == nil {
				t.Fatalf("returned status %d and a %d-byte body, want an error", status, len(body))
			}
			for _, w := range c.want {
				if !strings.Contains(err.Error(), w) {
					t.Errorf("error %q does not contain %q", err, w)
				}
			}
			if body != nil {
				t.Errorf("a body came back with the error: %x", body)
			}
		})
	}
}

// (e) A BCNT over CTAPHID's maximum is refused by its own error; the trailing continuations make a recv without the bound
// fail on the SEQ check instead, which the error text tells apart.
func TestCtapHID_OversizedMessage(t *testing.T) {
	cid := uint32(hidHighCID)
	recs := [][]byte{hidInitPkt(cid, ctaphidCBOR, 7610, hidFill(57, 0xAA))}
	for seq := 0; seq < 128; seq++ {
		recs = append(recs, hidContPkt(cid, byte(seq), hidFill(59, 0xBB)))
	}
	recs = append(recs, hidContPkt(cid, 0, hidFill(59, 0xBB)))
	h, _ := hidHost(t, cid, func([]byte) [][]byte { return recs }, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	_, body, err := h.cbor(0x01, nil)
	if err == nil {
		t.Fatalf("a %d-byte body came back, want an error", len(body))
	}
	for _, w := range []string{"7610", "7609"} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("error %q does not name %s", err, w)
		}
	}
	if strings.Contains(err.Error(), "SEQ") {
		t.Errorf("error %q is the SEQ check's, not the size bound's", err)
	}
	if body != nil {
		t.Errorf("a body came back with the error")
	}
}

// (f) send refuses a payload over the maximum before writing anything, and writes the maximum in 1 + 128 reports.
func TestCtapHID_SendSizeLimit(t *testing.T) {
	type drained struct {
		count  int
		seqs   []byte
		faults int
	}
	run := func(t *testing.T, size int) (error, drained) {
		a, b := hidPair(t)
		done := make(chan drained, 1)
		go func() {
			var d drained
			var rec [128]byte
			for {
				n, err := unix.Read(b, rec[:])
				if err != nil || n <= 1 { // EOF, or the one-byte end marker the test sends: a write is never that short
					done <- d
					return
				}
				d.count++
				rep, ok := hidUsbhid(rec[:n])
				if !ok {
					d.faults++
				} else if d.count > 1 {
					d.seqs = append(d.seqs, rep[4])
				}
			}
		}()
		h := &ctapHID{fd: a, cid: hidHighCID}
		err := h.send(ctaphidCBOR, hidFill(size, 0x11))
		// SEQPACKET keeps record order, so the marker arrives after every report; shutdown alone does not
		// wake the peer's read on every kernel.
		unix.Write(a, []byte{0xEE})
		unix.Shutdown(a, unix.SHUT_WR)
		return err, <-done
	}
	t.Run("7610", func(t *testing.T) {
		err, d := run(t, 7610)
		if err == nil || !strings.Contains(err.Error(), "7610") {
			t.Errorf("error %v, want one naming 7610", err)
		}
		if d.count != 0 {
			t.Errorf("%d records written, want 0", d.count)
		}
	})
	t.Run("7609", func(t *testing.T) {
		err, d := run(t, 7609)
		if err != nil {
			t.Fatalf("send: %v", err)
		}
		if d.count != 129 || d.faults != 0 {
			t.Errorf("%d records, %d framing faults; want 129 and 0", d.count, d.faults)
		}
		for i, s := range d.seqs {
			if int(s) != i {
				t.Fatalf("continuation %d carries SEQ %d", i, s)
			}
		}
	})
}

// (g) INIT answers that do not echo our nonce, or are too short, are errors.
func TestCtapHID_InitChannelErrors(t *testing.T) {
	t.Run("wrong nonce", func(t *testing.T) {
		h, _ := hidHost(t, hidHighCID, nil, func(nonce []byte) []byte {
			bad := append([]byte(nil), nonce...)
			bad[0] ^= 0xFF
			return append(bad, 0xA1, 0xB2, 0xC3, 0xD4, 0x02, 0x01, 0x00, 0x00, 0x00)
		})
		if err := h.initChannel(); err == nil || !strings.Contains(err.Error(), "bad nonce echo") {
			t.Errorf("error %v, want bad nonce echo", err)
		}
	})
	t.Run("short answer", func(t *testing.T) {
		h, _ := hidHost(t, hidHighCID, nil, func(nonce []byte) []byte { return append(append([]byte(nil), nonce...), hidFill(8, 0)...) })
		if err := h.initChannel(); err == nil {
			t.Errorf("a 16-byte INIT answer was accepted")
		}
	})
}

// (h) CTAPHID_ERROR and an empty CBOR answer are errors that say so.
func TestCtapHID_CBORErrors(t *testing.T) {
	cid := uint32(hidHighCID)
	cases := []struct {
		name, want string
		cmd        byte
		payload    []byte
	}{
		{"ctaphid error", "0x06", ctaphidError, []byte{0x06}},
		{"empty answer", "empty CTAP2 response", ctaphidCBOR, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, _ := hidHost(t, cid, func([]byte) [][]byte { return hidFrame(cid, c.cmd, c.payload) }, nil)
			if err := h.initChannel(); err != nil {
				t.Fatalf("initChannel: %v", err)
			}
			if _, _, err := h.cbor(0x01, nil); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("error %v, want one containing %q", err, c.want)
			}
		})
	}
}

// (i) The fake key's reader has returned by the time its test ends, before either fd is closed. One that outlived them
// read the next test's socket pair through the reused fd numbers and answered it: under load the high-cid round trip
// was allocated the low-cid test's 0x00000001, CBORErrors got the previous case's CTAPHID error, and a late t.Logf
// panicked the whole package (NWP-20261021-30).
func TestCtapHID_FakeKeyReaderEndsWithItsTest(t *testing.T) {
	var f *hidFake
	t.Run("session", func(t *testing.T) {
		var h *ctapHID
		h, f = hidHost(t, hidHighCID, nil, nil)
		if err := h.initChannel(); err != nil {
			t.Fatalf("initChannel: %v", err)
		}
	})
	select {
	case <-f.done:
	default:
		t.Fatal("the fake key's reader outlived its test")
	}
	if f.late {
		t.Fatal("the fake key's reader returned only after its fds were closed")
	}
}

// (j) A reader stopped while its answer is still being written, into a socket the host has stopped reading, ends too:
// the write waits by poll, never inside write(2).
func TestCtapHID_FakeKeyWriterEndsWithItsTest(t *testing.T) {
	var f *hidFake
	t.Run("session", func(t *testing.T) {
		flood := make([][]byte, 4000) // far over the socket's send buffer
		for i := range flood {
			flood[i] = hidInitPkt(hidHighCID, ctaphidKeepAlv, 1, []byte{0x02})
		}
		var h *ctapHID
		h, f = hidHost(t, hidHighCID, func([]byte) [][]byte { return flood }, nil)
		if err := h.send(ctaphidCBOR, []byte{0x01}); err != nil {
			t.Fatalf("send: %v", err)
		}
		for !f.flooding() {
			time.Sleep(time.Millisecond)
		}
	})
	select {
	case <-f.done:
	default:
		t.Fatal("the fake key's reader outlived its test")
	}
	if f.late {
		t.Fatal("the fake key's reader returned only after its fds were closed")
	}
}

// hidCborBy runs h.cbor in a goroutine and returns its error, failing the test when it has not returned within 2s.
func hidCborBy(t *testing.T, h *ctapHID) error {
	t.Helper()
	done := make(chan error, 1)
	go func() {
		_, _, err := h.cbor(0x01, nil)
		done <- err
	}()
	select {
	case err := <-done:
		return err
	case <-time.After(2 * time.Second):
		t.Fatal("cbor had not returned 2s into a 50ms recv budget")
		return nil
	}
}

// hidShrink sets one of ctap_hid.go's waits for this test only.
func hidShrink(t *testing.T, v *time.Duration, d time.Duration) {
	orig := *v
	*v = d
	t.Cleanup(func() { *v = orig })
}

// hidWantLink fails the test unless err is a *hidLinkError.
func hidWantLink(t *testing.T, err error) {
	t.Helper()
	var le *hidLinkError
	if err == nil || !errors.As(err, &le) {
		t.Fatalf("error %v (%T), want a *hidLinkError", err, err)
	}
}

// (k) NWP-20261113-09: a key that keeps answering KEEPALIVE restarts the per-report wait with every report, so only
// recv's budget ends it. The flood outlasts the budget on any runner; every record shares one backing array.
func TestCtapHID_RecvBudgetEndsAKeepaliveFlood(t *testing.T) {
	cid := uint32(hidHighCID)
	hidShrink(t, &ctaphidRecvBudget, 50*time.Millisecond)
	ka := hidInitPkt(cid, ctaphidKeepAlv, 1, []byte{0x02})
	flood := make([][]byte, 200000)
	for i := range flood {
		flood[i] = ka
	}
	h, _ := hidHost(t, cid, func([]byte) [][]byte { return flood }, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	hidWantLink(t, hidCborBy(t, h))
}

// (l) NWP-20261113-09: reports on another channel are skipped the same way, before the init packet and between it and
// its continuations; recv's budget bounds both.
func TestCtapHID_OtherChannelFloodIsBudgeted(t *testing.T) {
	cid := uint32(hidHighCID)
	other := hidInitPkt(0x55, ctaphidCBOR, 3, []byte{0x00, 0xEE, 0xEE})
	flood := func() [][]byte {
		recs := make([][]byte, 200000)
		for i := range recs {
			recs[i] = other
		}
		return recs
	}
	cases := []struct {
		name string
		recs [][]byte
	}{
		{"before-init", flood()},
		{"mid-message", append(append([][]byte{hidInitPkt(cid, ctaphidCBOR, 57+59, hidFill(57, 0xAA))}, flood()...),
			hidContPkt(cid, 0, hidFill(59, 0xBB)))},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hidShrink(t, &ctaphidRecvBudget, 50*time.Millisecond)
			h, _ := hidHost(t, cid, func([]byte) [][]byte { return c.recs }, nil)
			if err := h.initChannel(); err != nil {
				t.Fatalf("initChannel: %v", err)
			}
			hidWantLink(t, hidCborBy(t, h))
		})
	}
}

// (m) NWP-20261113-09: a key that answers nothing times out as a link error, so assertAnySlot does not ask the next slot.
func TestCtapHID_ReadTimeoutIsALinkError(t *testing.T) {
	hidShrink(t, &ctaphidReportWait, 50*time.Millisecond)
	h, _ := hidHost(t, hidHighCID, nil, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	hidWantLink(t, hidCborBy(t, h))
}

// (n) NWP-20261113-09, the control for (k)-(m): a framing refusal is a plain error, so the next slot's fresh session is
// still tried.
func TestCtapHID_FramingRefusalIsNotALinkError(t *testing.T) {
	cid := uint32(hidHighCID)
	cont := func(seq byte) []byte { return hidContPkt(cid, seq, hidFill(59, 0xBB)) }
	recs := [][]byte{hidInitPkt(cid, ctaphidCBOR, 57+3*59, hidFill(57, 0xAA)), cont(0), cont(2), cont(3)}
	h, _ := hidHost(t, cid, func([]byte) [][]byte { return recs }, nil)
	if err := h.initChannel(); err != nil {
		t.Fatalf("initChannel: %v", err)
	}
	err := hidCborBy(t, h)
	var le *hidLinkError
	if err == nil || errors.As(err, &le) {
		t.Fatalf("error %v (%T), want a plain framing refusal", err, err)
	}
}
