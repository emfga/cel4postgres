// Command confreport regenerates the committed conformance report by
// running the in-scope corpus against the database and against
// cel-go. It needs the test database up (docker compose up -d --wait);
// the report states what actually happened, so there is no way to
// produce it without running it.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/emfga/cel4postgres/conformance"
	"github.com/emfga/cel4postgres/internal/repo"
	"github.com/emfga/cel4postgres/internal/testdb"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "confreport:", err)
		os.Exit(1)
	}
}

func run() error {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	report, err := conformance.Build(ctx, conn)
	if err != nil {
		return err
	}

	root, err := repo.Root()
	if err != nil {
		return err
	}

	markdown := filepath.Join(root, conformance.ReportMarkdownPath)
	if err := os.WriteFile(
		markdown, []byte(report.Markdown()), 0o644,
	); err != nil {
		return err
	}

	sidecar, err := report.MarshalJSONReport()
	if err != nil {
		return err
	}
	jsonPath := filepath.Join(root, conformance.ReportJSONPath)
	if err := os.WriteFile(jsonPath, sidecar, 0o644); err != nil {
		return err
	}

	fmt.Printf(
		"wrote %s and %s: %d passed, %d failed, %d skipped, "+
			"%d divergences\n",
		conformance.ReportMarkdownPath, conformance.ReportJSONPath,
		report.Totals.Passed, report.Totals.Failed,
		report.Totals.Skipped, len(report.Divergences),
	)
	return nil
}
