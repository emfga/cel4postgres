package corpus

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/emfga/cel4postgres/internal/repo"
)

// The corpus is external input: these tests pin the facts the suite
// depends on -- the checkout is findable, every file parses, and the
// file census matches what the conformance target was measured
// against. A count change here means the corpus moved
// and the target needs re-measuring, not that this test is wrong.

func TestEveryFileParses(t *testing.T) {
	files, err := Files()
	if err != nil {
		t.Fatal(err)
	}

	// 25 included + 6 excluded at the pinned checkout.
	if len(files) != 31 {
		t.Errorf("corpus has %d files, the target was measured on 31",
			len(files))
	}

	for _, name := range files {
		file, err := Load(name)
		if err != nil {
			t.Errorf("load %s: %v", name, err)
			continue
		}
		// The declared name usually matches the filename, but not
		// always: type_deduction.textproto declares
		// "type_deductions". The suite keys by filename.
		if file.GetName() == "" {
			t.Errorf("%s.textproto declares no name", name)
		}
	}
}

func TestKnownCasePresent(t *testing.T) {
	file, err := Load("basic")
	if err != nil {
		t.Fatal(err)
	}

	for _, section := range file.GetSection() {
		if section.GetName() != "self_eval_zeroish" {
			continue
		}
		for _, tc := range section.GetTest() {
			if tc.GetName() == "self_eval_int_zero" {
				if tc.GetExpr() != "0" {
					t.Fatalf("self_eval_int_zero expr = %q", tc.GetExpr())
				}
				return
			}
		}
	}
	t.Fatal("basic/self_eval_zeroish/self_eval_int_zero not found")
}

// The pin lives in one place. CI checks the corpus out by commit, and
// a workflow that drifts from the constant would measure a different
// corpus than the report claims -- silently, since both would be
// internally consistent.
func TestPinMatchesWorkflow(t *testing.T) {
	root, err := repo.Root()
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(root, ".github", "workflows", "ci.yml")
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read ci.yml: %v", err)
	}

	pattern := regexp.MustCompile(
		`repository:\s*cel-expr/cel-spec\s*\n\s*ref:\s*([0-9a-f]{40})`,
	)

	match := pattern.FindSubmatch(source)
	if match == nil {
		t.Fatal("ci.yml does not check cel-expr/cel-spec out by commit")
	}

	if ref := string(match[1]); ref != Pin {
		t.Fatalf(
			"ci.yml checks out cel-spec %s but corpus.Pin says %s\n"+
				"The corpus defines what the conformance number means: "+
				"move both together, with a re-measurement behind it.",
			ref, Pin,
		)
	}
}

// The local checkout is measured against the same pin, so a developer
// whose cel-spec has wandered learns it here rather than from a
// conformance report that disagrees with everyone else's.
func TestCheckoutMatchesPin(t *testing.T) {
	head, err := HeadSHA()
	if err != nil {
		t.Fatal(err)
	}
	if head == "" {
		t.Skip("cel-spec checkout reports no commit")
	}

	if head != Pin {
		t.Fatalf(
			"the cel-spec checkout is at %s but corpus.Pin says %s\n"+
				"Check the corpus out at the pinned commit, or move "+
				"the pin deliberately.",
			head, Pin,
		)
	}
}
