package conformance

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/emfga/cel4postgres/internal/repo"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// TestReportCurrent keeps the committed conformance report identical
// to what a run produces now, the way TestSkipListCurrent keeps the
// skip list current. A report is a claim about this tree; a stale one
// is a false claim, and nothing else would notice it.
func TestReportCurrent(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	report, err := Build(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}

	sidecar, err := report.MarshalJSONReport()
	if err != nil {
		t.Fatal(err)
	}

	root, err := repo.Root()
	if err != nil {
		t.Fatal(err)
	}

	for path, want := range map[string]string{
		ReportMarkdownPath: report.Markdown(),
		ReportJSONPath:     string(sidecar),
	} {
		committed, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Errorf("read %s: %v", path, err)
			continue
		}
		if string(committed) != want {
			t.Errorf(
				"%s is stale: regenerate with: "+
					"go run ./internal/cmd/confreport", path,
			)
		}
	}
}
