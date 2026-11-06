package fuse

import (
	"bytes"
	"encoding/binary"
	"io"
	"log"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// Pins the NOWHERE PATCH in Server.handleRequest (NWP-20261016-31): a request
// whose opcode go-fuse cannot parse (the Android kernel's FUSE_CANONICAL_PATH,
// 2016) must be ANSWERED with -ENOSYS, not dropped. A dropped request leaves
// the kernel caller waiting forever, which wedges every on-demand media read.

const nowhereCanonicalPathOpcode = 2016

// nowhereTestServer builds the smallest Server handleRequest needs, with the
// "device" being the write end of a pipe so the reply can be read back.
func nowhereTestServer(t *testing.T) (*Server, *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	t.Cleanup(func() { w.Close() })
	ms := &Server{
		mountFd: int(w.Fd()),
		opts:    &MountOptions{Logger: log.New(io.Discard, "", 0)},
	}
	ms.reqPool.New = func() interface{} {
		return &requestAlloc{request: request{cancel: make(chan struct{})}}
	}
	ms.readPool.New = func() interface{} {
		b := make([]byte, _FUSE_MIN_READ_BUFFER)
		return &b
	}
	return ms, r
}

func nowhereRequest(ms *Server, buf []byte) *requestAlloc {
	req := ms.reqPool.Get().(*requestAlloc)
	req.inputBuf = buf
	return req
}

// nowhereReadReply reads whatever handleRequest wrote, with a deadline. It
// returns nil if nothing arrives in time.
func nowhereReadReply(t *testing.T, r *os.File) []byte {
	t.Helper()
	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := r.Read(buf)
		got <- buf[:n]
	}()
	select {
	case b := <-got:
		return b
	case <-time.After(500 * time.Millisecond):
		return nil
	}
}

func TestNowhereCanonicalPathGetsENOSYS(t *testing.T) {
	ms, r := nowhereTestServer(t)
	hdr := int(unsafe.Sizeof(InHeader{}))
	buf := make([]byte, hdr)
	in := (*InHeader)(unsafe.Pointer(&buf[0]))
	in.Length = uint32(len(buf))
	in.Opcode = nowhereCanonicalPathOpcode
	in.Unique = 0x1122334455667788

	ms.handleRequest(nowhereRequest(ms, buf))

	reply := nowhereReadReply(t, r)
	if reply == nil {
		t.Fatal("no reply written for an unparseable request: the kernel caller would wait forever")
	}
	outSize := int(unsafe.Sizeof(OutHeader{}))
	if len(reply) != outSize {
		t.Fatalf("reply is %d bytes, want exactly one %d-byte OutHeader", len(reply), outSize)
	}
	var out OutHeader
	if err := binary.Read(bytes.NewReader(reply), binary.NativeEndian, &out); err != nil {
		t.Fatal(err)
	}
	if out.Unique != 0x1122334455667788 {
		t.Errorf("reply Unique = %#x, want the request's", out.Unique)
	}
	if out.Status != -int32(syscall.ENOSYS) {
		t.Errorf("reply Error = %d, want %d (-ENOSYS)", out.Status, -int32(syscall.ENOSYS))
	}
	if int(out.Length) != outSize {
		t.Errorf("reply Length = %d, want %d", out.Length, outSize)
	}
}

func TestNowhereShortRequestGetsNoReply(t *testing.T) {
	ms, r := nowhereTestServer(t)
	buf := make([]byte, int(unsafe.Sizeof(InHeader{}))-1)

	ms.handleRequest(nowhereRequest(ms, buf))

	if reply := nowhereReadReply(t, r); reply != nil {
		t.Fatalf("a request too short for an InHeader was answered with %d bytes", len(reply))
	}
}

// The cases below pin the log side of the same patch (NWP-20261127-11). The
// kernel sends FUSE_CANONICAL_PATH several times a second, and a line for each
// pushed every other line out of mediad.log. So 2016 logs ONE line per process
// (mediad runs one Server per media mount), and every other unknown opcode
// still logs each time, so a real protocol change stays visible.

// nowhereCaptureLog resets the once-per-process guard and routes the package
// log to a buffer until the test ends.
func nowhereCaptureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	nowhereResetCanonicalPathLog()
	var buf bytes.Buffer
	oldOut, oldFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(oldOut)
		log.SetFlags(oldFlags)
		nowhereResetCanonicalPathLog()
	})
	return &buf
}

// nowhereLoggedServer is nowhereTestServer with its Logger writing to a buffer.
func nowhereLoggedServer(t *testing.T) (*Server, *os.File, *bytes.Buffer) {
	t.Helper()
	ms, r := nowhereTestServer(t)
	var buf bytes.Buffer
	ms.opts.Logger = log.New(&buf, "", 0)
	return ms, r, &buf
}

// nowhereSendOpcode sends one InHeader-sized request and checks that it is
// answered with exactly one -ENOSYS OutHeader that carries its Unique.
func nowhereSendOpcode(t *testing.T, ms *Server, r *os.File, opcode uint32, unique uint64) {
	t.Helper()
	buf := make([]byte, int(unsafe.Sizeof(InHeader{})))
	in := (*InHeader)(unsafe.Pointer(&buf[0]))
	in.Length = uint32(len(buf))
	in.Opcode = opcode
	in.Unique = unique

	ms.handleRequest(nowhereRequest(ms, buf))

	reply := nowhereReadReply(t, r)
	if len(reply) != int(unsafe.Sizeof(OutHeader{})) {
		t.Fatalf("opcode %d: reply is %d bytes, want one OutHeader", opcode, len(reply))
	}
	var out OutHeader
	if err := binary.Read(bytes.NewReader(reply), binary.NativeEndian, &out); err != nil {
		t.Fatal(err)
	}
	if out.Unique != unique || out.Status != -int32(syscall.ENOSYS) {
		t.Fatalf("opcode %d: reply Unique=%#x Status=%d, want %#x and %d (-ENOSYS)",
			opcode, out.Unique, out.Status, unique, -int32(syscall.ENOSYS))
	}
}

// nowhereLines returns the non-empty lines of all the buffers.
func nowhereLines(bufs ...*bytes.Buffer) []string {
	var lines []string
	for _, b := range bufs {
		for _, l := range strings.Split(b.String(), "\n") {
			if l != "" {
				lines = append(lines, l)
			}
		}
	}
	return lines
}

func TestNowhereCanonicalPathLogsOnce(t *testing.T) {
	pkgLog := nowhereCaptureLog(t)
	ms, r, srvLog := nowhereLoggedServer(t)

	for i := uint64(1); i <= 3; i++ {
		nowhereSendOpcode(t, ms, r, nowhereCanonicalPathOpcode, i)
	}

	lines := nowhereLines(pkgLog, srvLog)
	if len(lines) != 1 || !strings.Contains(lines[0], "FUSE_CANONICAL_PATH (opcode 2016)") {
		t.Fatalf("three FUSE_CANONICAL_PATH requests logged %d lines, want exactly one FUSE_CANONICAL_PATH line: %q",
			len(lines), lines)
	}
}

func TestNowhereOtherUnknownOpcodeStillLogs(t *testing.T) {
	const opcode = 999
	if getHandler(opcode) != nil {
		t.Fatalf("precondition: go-fuse has a handler for opcode %d; pick an unknown one", opcode)
	}
	pkgLog := nowhereCaptureLog(t)
	ms, r, srvLog := nowhereLoggedServer(t)

	nowhereSendOpcode(t, ms, r, opcode, 7)

	if !strings.Contains(pkgLog.String(), "Unknown opcode 999") {
		t.Errorf("package log = %q, want an 'Unknown opcode 999' line", pkgLog.String())
	}
	if !strings.Contains(srvLog.String(), "parseRequest:") {
		t.Errorf("Server log = %q, want a 'parseRequest:' line", srvLog.String())
	}
}

func TestNowhereCanonicalPathOncePerProcess(t *testing.T) {
	pkgLog := nowhereCaptureLog(t)
	msA, rA, logA := nowhereLoggedServer(t)
	nowhereSendOpcode(t, msA, rA, nowhereCanonicalPathOpcode, 1)
	if n := len(nowhereLines(pkgLog, logA)); n != 1 {
		t.Fatalf("the first Server logged %d lines for its first FUSE_CANONICAL_PATH, want 1", n)
	}
	pkgBefore := pkgLog.Len()

	// A second mount in the same process, guard not reset.
	msB, rB, logB := nowhereLoggedServer(t)
	nowhereSendOpcode(t, msB, rB, nowhereCanonicalPathOpcode, 2)

	if logB.Len() != 0 || pkgLog.Len() != pkgBefore {
		t.Fatalf("a second Server logged FUSE_CANONICAL_PATH again: Server log %q, package log gained %q",
			logB.String(), pkgLog.String()[pkgBefore:])
	}
}
