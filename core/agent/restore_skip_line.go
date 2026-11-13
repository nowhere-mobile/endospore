package main

import (
	"fmt"
	"path/filepath"
)

// restoreSkipLine is the log line for an entry untarFrom could not write (h60 #9, `docs/product-decisions.md`
// 2026-11-06, the pattern of Q001 (e), 2026-10-20: the line that writes the log changes, the scrub stays as it is).
// It names the package, or a fixed scope word when the entry has none, and the error code, never a path. A name
// that is not a package name is a file at a user root, so it takes the scope. The error is only its code because a
// *fs.PathError repeats the path unquoted, and the scrub keeps a [restore] line's quotes by design. media_server.go's
// INCOMPLETE line sends the reader to the `[restore] skip ` prefix, so that literal stays.
func restoreSkipLine(dir, name, what string, err error) string {
	full := filepath.Join(dir, name)
	subject := "scope=" + blindScopeOf(full)
	if p := blindPkgOf(full); p != "" && validPkgName(p) {
		subject = "pkg=" + p
	}
	code := errCode(err)
	if what != "" {
		return fmt.Sprintf("[restore] skip %s: %s: %s\n", subject, what, code)
	}
	return fmt.Sprintf("[restore] skip %s: %s\n", subject, code)
}
