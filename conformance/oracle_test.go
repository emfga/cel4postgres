package conformance

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"cel.dev/cel-go/common/types"

	"github.com/emfga/cel4postgres/internal/oracle"
	"github.com/emfga/cel4postgres/internal/repo"
)

// Conformance compares cel4postgres against cel-go. These tests assert
// the reference side of that comparison is present and working, so a
// later disagreement is never explained by a broken oracle.

func TestReferenceImplementationEvaluates(t *testing.T) {
	value, err := oracle.Eval("1 + 1 == 2", nil)
	if err != nil {
		t.Fatalf("evaluate with cel-go: %v", err)
	}

	if value != types.True {
		t.Fatalf("cel-go evaluated 1 + 1 == 2 to %v, want true", value)
	}
}

// The pinned version is part of what a conformance number means: the
// set of expressions the two implementations agree on moves with it.
// A bump that arrives as a transitive upgrade would silently change
// the measurement, so go.mod is checked against the version the code
// declares.
//
// go.mod is read rather than debug.ReadBuildInfo(), which reports no
// dependencies at all from a test binary.
func TestReferenceImplementationVersionPinned(t *testing.T) {
	root, err := repo.Root()
	if err != nil {
		t.Fatal(err)
	}

	source, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}

	pattern := regexp.MustCompile(`(?m)^\s*cel\.dev/cel-go\s+(v\S+)`)

	match := pattern.FindSubmatch(source)
	if match == nil {
		t.Fatal("cel.dev/cel-go is not required by go.mod")
	}

	if version := string(match[1]); version != oracle.Version {
		t.Fatalf(
			"go.mod pins cel.dev/cel-go %s but oracle.Version says %s\n"+
				"An upgrade re-measures conformance: change the constant "+
				"deliberately, with a run behind it.",
			version, oracle.Version,
		)
	}
}
