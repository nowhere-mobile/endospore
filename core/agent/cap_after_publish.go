package main

// NWP-20261123-01: WORK THAT MUST WAIT FOR A POINTER TO LAND IN THE STORE.
//
// In cap mode putRefBytesGuarded only BUFFERS a pointer and returns true; the deferred capFlush uploads the
// blobs and PUTs the pointers minutes later. putHeadGuarded's receipt re-anchor and pushProfile's
// writeRestoreReceipt ran at the buffer, so a blob PUT that failed, a pointer PUT that failed, or a head the
// publish pass refused left the receipt on a head the store never got. The next seal then compared that
// receipt with the stored head and logged STALE BASE, and with NOWHERE_SEQ_GUARD=1 every later seal refused
// (frankel NW-b636a742c916, an ERR-PUSH PARTIAL:vault=failed after a store PUT reset).
//
// capAfterPublish registers such work on the open bracket, keyed by the pointer. capFlush runs it right after
// that pointer's PUT returns in the publish pass, and never otherwise: a skipped pointer (fence, stale, a refused
// gate, the wallet head), a tombstone, a panic, a stop and an abort all drop it with the bracket's capState.
// Outside a buffering bracket the pointer was written directly and has already landed, so the work runs at once,
// exactly as before.

import (
	"bytes"
	"fmt"
	"os"
	"strings"
)

// capHook is one piece of work waiting for a pointer's PUT. want is the value buffered for the pointer when the
// work was registered (nil if none was): the work runs only after THAT value lands.
type capHook struct {
	want []byte
	fn   func()
}

// capAfterPublish runs fn once the pointer ref has landed in the store: at once outside a buffering cap bracket,
// else after capFlush's PUT of ref. fn never runs under capWriteMu.
func capAfterPublish(ref string, fn func()) {
	key := "ref/" + strings.TrimPrefix(ref, "ref/")
	capWriteMu.Lock()
	if capBuffering && capCur != nil {
		var want []byte
		if v, ok := capCur.refs[key]; ok {
			want = append([]byte(nil), v...)
		}
		if capCur.after == nil {
			capCur.after = map[string][]capHook{}
		}
		capCur.after[key] = append(capCur.after[key], capHook{want: want, fn: fn})
		capWriteMu.Unlock()
		return
	}
	capWriteMu.Unlock()
	fn()
}

// runAfterPublish runs, and removes, the hooks registered for key whose value is v. capFlush calls it only after
// the PUT of v at key landed. A hook registered for another value -- the pointer was not buffered (a refusal at
// the buffer), or was rewritten later in the bracket -- does not run. Never for a tombstone.
func (st *capState) runAfterPublish(key string, v []byte) {
	hooks := st.after[key]
	delete(st.after, key)
	if len(v) == 0 {
		return
	}
	for _, h := range hooks {
		if h.want != nil && bytes.Equal(h.want, v) {
			h.fn()
		}
	}
}

// capPointerLanded settles a pointer PUT that failed after its retries: the store may have applied it and the
// answer been lost (a reset on every attempt). It reads the pointer once, as stalePublish does, and reports true
// only when the store holds exactly want. One line either way, with no ref and no profile in it.
func capPointerLanded(key string, want []byte) bool {
	var got []byte
	var ok bool
	if err := recovered(func() { got, ok = getRefBytes("s3", strings.TrimPrefix(key, "ref/")) }); err == nil && ok && bytes.Equal(got, want) {
		fmt.Fprintf(os.Stderr, "  cap-flush: a pointer PUT failed, but one read shows the store holds the value written -- counted as landed (NWP-20261123-01)\n")
		return true
	}
	fmt.Fprintf(os.Stderr, "  cap-flush: a pointer PUT failed, and one read shows the store does not hold the value written -- the flush fails (NWP-20261123-01)\n")
	return false
}
