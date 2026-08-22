// Package repo locates the repository root.
//
// Tests run with the working directory set to their own package, so
// anything that reads a file checked in at the root -- .env, go.mod --
// has to walk up to find it. Doing that in one place keeps every
// package's idea of "the root" identical.
package repo

import (
	"fmt"
	"os"
	"path/filepath"
)

// Root returns the directory holding go.mod, walking up from the
// working directory.
func Root() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}

	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no go.mod found above %q", dir)
		}
		dir = parent
	}
}
