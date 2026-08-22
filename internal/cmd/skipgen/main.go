// Command skipgen regenerates conformance/skipped_cases.go from the
// corpus. Run it after moving the cel-spec checkout to a new commit;
// the diff of the generated file is how a corpus update is reviewed.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/emfga/cel4postgres/conformance"
	"github.com/emfga/cel4postgres/internal/repo"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "skipgen:", err)
		os.Exit(1)
	}
}

func run() error {
	skipped, err := conformance.GenerateSkippedCases()
	if err != nil {
		return err
	}

	root, err := repo.Root()
	if err != nil {
		return err
	}

	path := filepath.Join(root, "conformance", "skipped_cases.go")
	source := conformance.RenderSkippedCases(skipped)
	if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
		return err
	}

	fmt.Printf("wrote %d skipped cases to %s\n", len(skipped), path)
	return nil
}
