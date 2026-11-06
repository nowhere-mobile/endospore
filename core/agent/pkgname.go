package main

// validPkgName reports whether s is an Android package name:
// ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$, at most 255 bytes. The app-code verbs join the name into a
// path and recursively delete it, so "." and ".." (which pass a bare slash test) must not get through. A name needs
// at least two segments, and no segment may be empty or start with a digit or underscore.
func validPkgName(s string) bool {
	if len(s) == 0 || len(s) > 255 {
		return false
	}
	segs, start := 0, true
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '.':
			if start {
				return false
			}
			start = true
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z':
			if start {
				segs++
			}
			start = false
		case c >= '0' && c <= '9', c == '_':
			if start {
				return false
			}
		default:
			return false
		}
	}
	return !start && segs >= 2
}
