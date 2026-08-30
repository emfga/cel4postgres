package conformance

import (
	"context"
	"fmt"
	"os"
	"sort"
	"testing"

	"github.com/emfga/cel4postgres/internal/corpus"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// TestMain prints the skip report before the run: every file-level
// skip with its reason, and the count of case-level skips. Coverage
// must never shrink silently, so what is not attempted is announced
// on every run, not discoverable only with -v.
func TestMain(m *testing.M) {
	files := make([]string, 0, len(SkippedFiles))
	for file := range SkippedFiles {
		files = append(files, file)
	}
	sort.Strings(files)

	fmt.Printf("conformance: skipping %d corpus files:\n", len(files))
	for _, file := range files {
		fmt.Printf("  %-12s %s\n", file, SkippedFiles[file])
	}
	fmt.Printf(
		"conformance: skipping %d cases inside included files "+
			"(conformance/skipped_cases.go)\n",
		len(skippedCases),
	)

	os.Exit(m.Run())
}

// TestSkipListCurrent keeps the committed skip list identical to what
// the generator derives from the corpus, so the two cannot drift.
func TestSkipListCurrent(t *testing.T) {
	want, err := GenerateSkippedCases()
	if err != nil {
		t.Fatal(err)
	}

	if RenderSkippedCases(want) != RenderSkippedCases(skippedCases) {
		t.Fatal(
			"skipped_cases.go is stale for this corpus checkout: " +
				"regenerate with: go run ./internal/cmd/skipgen",
		)
	}
}

// TestSimple runs the cel-spec simple conformance corpus. Subtests are
// named <file>/<section>/<case> so the single-file and single-case
// selectors work:
//
//	go test ./conformance/... -run TestSimple/basic
//	go test ./conformance/... -run TestSimple/basic/self_eval_zeroish/self_eval_int_zero
func TestSimple(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	stages, err := InstalledStages(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}

	files, err := corpus.Files()
	if err != nil {
		t.Fatal(err)
	}

	for _, file := range files {
		t.Run(file, func(t *testing.T) {
			if reason, ok := SkippedFiles[file]; ok {
				t.Skip(reason)
			}

			parsed, err := corpus.Load(file)
			if err != nil {
				t.Fatal(err)
			}

			for _, section := range parsed.GetSection() {
				t.Run(section.GetName(), func(t *testing.T) {
					for _, tc := range section.GetTest() {
						t.Run(tc.GetName(), func(t *testing.T) {
							result := RunCase(ctx, conn, stages,
								file, section.GetName(), tc)
							switch result.Status {
							case Skipped:
								t.Skip(result.Detail)
							case Failed:
								t.Fatal(result.Detail)
							}
						})
					}
				})
			}
		})
	}
}
