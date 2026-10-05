package main

import "runtime/debug"

// buildVersion is the git commit this binary was built from (go build stamps it), e.g. "aae9275" or
// "aae9275+dirty", and that commit's time (RFC 3339). "dev" for go run or a build outside the repo.
func buildVersion() (rev, at string) {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return "dev", ""
	}
	dirty := false
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value[:min(7, len(s.Value))]
		case "vcs.time":
			at = s.Value
		case "vcs.modified":
			dirty = s.Value == "true"
		}
	}
	if rev == "" {
		return "dev", ""
	}
	if dirty {
		rev += "+dirty"
	}
	return rev, at
}
