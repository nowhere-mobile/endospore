package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// NWP-20261205-07: COPY AN EXPORT FOLDER INTO A STORE THE USER RUNS, IN ONE COMMAND.
//
// Decided 2026-11-14 (docs/product-decisions.md, "2026-11-14 — DECIDED: five answers to harvest 65 — every
// recommendation accepted", F14 option A, "build the verb"). profile-export-restore.md §6 gave only a three-step
// operator recipe (export-manifest, any S3 tool, verify-manifest), and a raw S3 copy reaches none of §2's guards.
// This verb is that recipe with the guards in it. The user runs it on their own computer:
//
//	S3_ENDPOINT=... S3_REGION=... S3_BUCKET=... S3_ACCESS_KEY=... S3_SECRET_KEY=... \
//	  nowhere_agent copy-export s3 <export-folder> [--deep]
//
// ⚠ THE STORE KEYS COME FROM THE ENVIRONMENT ONLY. An argument shows in the process list. The verb never prints an
// S3_* value and never prints a store error: the error text can carry the endpoint and a request signature.
//
// The steps, in this order and for these reasons:
//  1. refuse before any store request: not s3, our gateway (capMode), an empty S3_* variable, a manifest that does
//     not decode, a key that is not blob/<64 hex> or ref/<name> or whose path leaves the folder;
//  2. restore-preflight's refusals (§2): a destination that holds the profile under a different head, newer or
//     older, or a head it cannot read. A raw ref PUT is unconditional, so a copy over a live profile rolls its head
//     back and orphans everything sealed since (NWP-20260918-04);
//  3. the folder check: a short or damaged folder must not become a short store;
//  4. the blobs; 5. the refs, after every blob (a head naming absent blobs cannot restore);
//  6. the manifest LAST: its presence is the only cheap signal that the copy ran to the end;
//  7. verify-manifest against the destination: the destination, not the copy loop, is the proof.
//
// It uses s3PutGuarded directly, NOT postBlob (blob cache, cap bracket) or putRef (seal fence): the verb holds no
// DK and no profile name, and the destination is a plain bucket under the user's keys.

var copyExportBlobKeyRE = regexp.MustCompile(`^blob/[0-9a-f]{64}$`)

// runCopyExport is the copy-export verb. It returns the process exit code: 0 only when the destination verifies;
// every refusal and every failure is 2.
func runCopyExport(base, folder string, deep bool) int {
	if !isS3(base) {
		fmt.Fprintln(os.Stderr, "copy-export: the store must be s3 -- this verb writes into a bucket you run, "+
			"under your own keys")
		return 2
	}
	if capMode() {
		fmt.Fprintln(os.Stderr, "copy-export: GATEWAY_URL is set and S3_ACCESS_KEY is not -- this verb runs "+
			"under your own store's keys, never through a gateway")
		return 2
	}
	for _, k := range []string{"S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY"} {
		if os.Getenv(k) == "" {
			fmt.Fprintf(os.Stderr, "copy-export: %s is empty -- put your own store's S3_* variables in the "+
				"environment\n", k)
			return 2
		}
	}
	mb, err := os.ReadFile(filepath.Join(folder, "manifest.json"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: the export folder holds no readable manifest.json -- nothing was written")
		return 2
	}
	m, err := decodeExportManifest(mb)
	if err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: "+err.Error())
		return 2
	}
	if err := copyExportCheckKeys(folder, m); err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: "+err.Error()+" -- nothing was written")
		return 2
	}

	// step 3: restore-preflight's refusals, before any write
	var pf *PreflightReport
	if err := copyExportStore(func() { pf = preflightRestore(base, m) }); err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: the store did not answer the preflight reads -- nothing was written; re-run")
		return 2
	}
	copyExportSrcVersions(folder, m, pf)
	fmt.Print(pf.summary())
	if !pf.Safe() {
		fmt.Fprintln(os.Stderr, "copy-export: REFUSING -- this profile is already live in the "+
			"destination with a head that differs or could not be read. Copying over it would overwrite the head refs and orphan "+
			"everything sealed since, with nothing on the path saying so (NWP-20260918-04).")
		return 2
	}

	// step 4: the folder holds what its manifest names
	if err := copyExportCheckFolder(folder, m); err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: "+err.Error()+" -- the folder is short or damaged; nothing was written")
		return 2
	}

	written, skipped := 0, 0
	// step 5: the blobs, in manifest order; one already present at its full length is not written again
	for _, b := range m.Blobs {
		data, err := os.ReadFile(copyExportPath(folder, b.Key))
		if err != nil {
			fmt.Fprintf(os.Stderr, "copy-export: %s cannot be read from the folder -- stopped; re-run to resume\n", b.Key)
			return 2
		}
		if sz, ok := copyExportSize(b.Key); ok && sz == int64(len(data)) {
			skipped++
			continue
		}
		if !copyExportPut("blob", b.Key, data) {
			return 2
		}
		written++
	}
	// step 6: the refs, after every blob
	for _, r := range m.Refs {
		if !copyExportPut("ref", r.Key, []byte(r.Value)) {
			return 2
		}
		written++
	}
	// step 7: the manifest LAST
	if !copyExportPut("manifest", "manifest.json", mb) {
		return 2
	}
	written++

	// step 8: verify-manifest against the destination
	var rep *VerifyReport
	if err := copyExportStore(func() { rep = verifyExportManifest(base, m, deep) }); err != nil {
		fmt.Fprintln(os.Stderr, "copy-export: the store did not answer the verify reads -- re-run to resume")
		return 2
	}
	fmt.Print(rep.summary())
	if !rep.ok() {
		fmt.Fprintln(os.Stderr, "copy-export: INCOMPLETE -- do not log in against this store. A "+
			"missing deferred object does NOT announce itself: login and the next seal both go green "+
			"and publish a head naming objects that are not there (NWP-20260919-05).")
		return 2
	}
	fmt.Printf("copy-export: COMPLETE -- %d object(s) written, %d blob(s) already present; every object the export "+
		"recorded is present%s\n", written, skipped, map[bool]string{true: " and hashes correctly", false: ""}[deep])
	return 0
}

// copyExportPath is where a manifest key lives in the export folder (exportwalk.mjs writeFolder's layout).
func copyExportPath(folder, key string) string {
	return filepath.Join(folder, filepath.FromSlash(key))
}

// copyExportCheckKeys refuses a key the verb would not write as-is, or whose folder path is not under the folder.
// It runs before any store request: the manifest is the user's file, and a key such as ref/../../etc/x would make
// the verb read outside the folder and write a key no restore reads.
func copyExportCheckKeys(folder string, m *ExportManifest) error {
	inside := func(key string) error {
		if strings.HasPrefix(key, "/") || strings.ContainsAny(key, "\\\x00") {
			return fmt.Errorf("key %q leaves the export folder", key)
		}
		for _, seg := range strings.Split(key, "/") {
			if seg == "" || seg == "." || seg == ".." {
				return fmt.Errorf("key %q leaves the export folder", key)
			}
		}
		rel, err := filepath.Rel(folder, copyExportPath(folder, key))
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("key %q leaves the export folder", key)
		}
		return nil
	}
	for _, b := range m.Blobs {
		if !copyExportBlobKeyRE.MatchString(b.Key) {
			return fmt.Errorf("blob key %q is not blob/<64 lower-case hex>", b.Key)
		}
		if err := inside(b.Key); err != nil {
			return err
		}
	}
	for _, r := range m.Refs {
		if n, ok := strings.CutPrefix(r.Key, "ref/"); !ok || n == "" {
			return fmt.Errorf("ref key %q is not ref/<name>", r.Key)
		}
		if err := inside(r.Key); err != nil {
			return err
		}
	}
	return nil
}

// copyExportSrcVersions fills the export's head version for each differing ref. preflightRestore reads the
// EXPORT's head blob from the DESTINATION, where it is absent before a copy, so SrcVersion stays 0 and the
// summary cannot say newer or older. The folder holds that head: read its Version there. A head that cannot be
// read leaves 0; the refusal does not depend on this, only the words do.
func copyExportSrcVersions(folder string, m *ExportManifest, pf *PreflightReport) {
	val := map[string]string{}
	for _, r := range m.Refs {
		val[r.Key] = r.Value
	}
	for i := range pf.Verdicts {
		v := &pf.Verdicts[i]
		if v.State != "differs" || v.SrcVersion != 0 {
			continue
		}
		key := "blob/" + val[v.Key]
		if !copyExportBlobKeyRE.MatchString(key) {
			continue
		}
		b, err := os.ReadFile(copyExportPath(folder, key))
		if err != nil {
			continue
		}
		if vt, ok := parseVault(b); ok {
			v.SrcVersion = vt.Version
		}
	}
}

// copyExportCheckFolder proves the folder holds what its manifest names, before any write: each blob hashes to
// its key and has its recorded size, and each ref file holds the recorded value.
func copyExportCheckFolder(folder string, m *ExportManifest) error {
	for _, b := range m.Blobs {
		f, err := os.Open(copyExportPath(folder, b.Key))
		if err != nil {
			return fmt.Errorf("%q is missing from the folder", b.Key)
		}
		h := sha256.New()
		n, err := io.Copy(h, f)
		f.Close()
		if err != nil {
			return fmt.Errorf("%q cannot be read from the folder", b.Key)
		}
		if "blob/"+hex.EncodeToString(h.Sum(nil)) != b.Key {
			return fmt.Errorf("%q does not hash to its key", b.Key)
		}
		if b.Size >= 0 && n != b.Size {
			return fmt.Errorf("%q holds %d bytes, the manifest records %d", b.Key, n, b.Size)
		}
	}
	for _, r := range m.Refs {
		got, err := os.ReadFile(copyExportPath(folder, r.Key))
		if err != nil {
			return fmt.Errorf("%q is missing from the folder", r.Key)
		}
		if strings.TrimRight(string(got), " \t\r\n") != r.Value {
			return fmt.Errorf("%q does not hold the value the manifest records", r.Key)
		}
	}
	return nil
}

// copyExportSize is s3Size under copyExportStore. A store that does not answer reads as absent: the blob is then
// written again, which is safe (its key is its hash).
func copyExportSize(key string) (int64, bool) {
	var sz int64
	var ok bool
	if err := copyExportStore(func() { sz, ok = s3Size(key) }); err != nil {
		return 0, false
	}
	return sz, ok
}

// copyExportPut writes one object. A write error or a panic prints one FIXED line: never the error text, which can
// carry the endpoint and a request signature, and never an S3_* value.
func copyExportPut(kind, key string, data []byte) bool {
	var werr error
	if err := copyExportStore(func() { werr = s3PutGuarded(key, data, nil) }); err != nil || werr != nil {
		fmt.Fprintf(os.Stderr, "copy-export: the store refused or did not answer the %s write of %s -- stopped; "+
			"re-run to resume\n", kind, key)
		return false
	}
	return true
}

// copyExportStore runs one step's store calls under recovered, with os.Stdout and os.Stderr pointed at the null
// device for the duration. The store path prints as it retries (retryStoreWithinGuarded's "  retry ..." lines,
// logStoreGiveUpOnce): logSafeStoreErr strips URL queries and profile names, but not the endpoint, and not a key
// a transport error may carry. Those lines suit a daemon log on our own device, not a terminal the user may paste
// into a bug report. Every line this verb prints about a store call is its own fixed line, printed after this
// returns. The verb runs no goroutine, so the swap covers every write the call makes.
func copyExportStore(f func()) error {
	null, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = null, null
	defer func() {
		os.Stdout, os.Stderr = oldOut, oldErr
		null.Close()
	}()
	return recovered(f)
}
