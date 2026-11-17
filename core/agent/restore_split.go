package main

// NWP-20261203-09: WHERE A SIGN-IN RESTORE'S TIME GOES, AS SIGN-IN SUMMARY FIELDS.
//
// The backlog row "A sign-in fetches every CE vault chunk fresh: nothing is cached across sessions, so a large
// profile spends 5-7 minutes on the vault alone": the tickets give only signin_vault_ms and the chunk counts, so
// nothing says if the time went to the network or to the untar, and no throughput can be worked out without bytes.
// The ordered writer in cdcRestoreProg sees both sides. It waits on futures[i] when the store is late, and it blocks
// in pw.Write while the untar consumes the chunk: io.Pipe is synchronous, so that time holds the untar's creates,
// writes and copyDropCache's per-file fsync. Both passes of restoreSkippingParked add to the same counters; the
// heal's own fetch loop is not timed (it has heal_ms).
//
// restoreFetchedBytes counts the SEALED bytes (what travels the wire, the unit of m.Sizes) of every store-miss
// getChunk in this process, the heal's fetches included, as fetched= counts them. A chunk-cache hit adds nothing.
// The three unfetched counters are restoreSkippingParked's skip: packages, plaintext bytes and chunks not fetched,
// 0 when the skip is off.
//
// One restore verb is one process, so production never resets them. signinSummaryAppend writes them on the scope
// line. Diagnostics only: nothing about what is restored, or when, changes.

var restoreFetchedBytes, restoreWaitNs, restoreWriteNs int64                  // atomic
var restoreUnfetchedPkgs, restoreUnfetchedBytes, restoreUnfetchedChunks int64 // atomic

// cdcFetchChunk and cdcUntar are cdcRestoreProg's fetch and untar seams; tests swap them.
var cdcFetchChunk = getChunk
var cdcUntar = untarFrom
