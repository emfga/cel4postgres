package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/cel4postgres/internal/corpus"
	"github.com/emfga/cel4postgres/internal/oracle"
)

// The conformance report is the durable form of what the suite
// prints. A number that lives only in terminal scrollback cannot be
// cited, dated or reproduced, and a skip nobody sees is a silent
// scope reduction -- so the corpus run is rendered to a committed
// document, and a test keeps it current.
//
// Provenance carries no timestamp. Everything that decides the
// numbers -- the corpus commit, the cel-go pin, the PostgreSQL major
// version -- is an input, and dating the file instead would make the
// staleness test go red once a day for no reason.

// The committed report, relative to the repository root.
const (
	ReportMarkdownPath = "docs/conformance-report.md"
	ReportJSONPath     = "docs/conformance-report.json"
)

// Report is one full run of the in-scope corpus, from both sides.
type Report struct {
	CelSpec      string        `json:"cel_spec"`
	CelGo        string        `json:"cel_go"`
	Postgres     string        `json:"postgres"`
	Totals       Totals        `json:"totals"`
	Files        []FileReport  `json:"files"`
	SkippedFiles []FileSkip    `json:"skipped_files"`
	SkippedCases []CaseSkip    `json:"skipped_cases"`
	Divergences  []Divergence  `json:"divergences"`
	Failures     []CaseFailure `json:"failures"`
}

// Totals counts the whole corpus, attempted and not.
type Totals struct {
	Files        int `json:"files"`
	SkippedFiles int `json:"skipped_files"`
	Cases        int `json:"cases"`
	Passed       int `json:"passed"`
	Skipped      int `json:"skipped"`
	Failed       int `json:"failed"`
}

// FileReport is one attempted corpus file.
type FileReport struct {
	Name    string `json:"name"`
	Env     string `json:"env"`
	Cases   int    `json:"cases"`
	Passed  int    `json:"passed"`
	Skipped int    `json:"skipped"`
	Failed  int    `json:"failed"`
}

// FileSkip is a corpus file not attempted at all.
type FileSkip struct {
	Name   string `json:"name"`
	Cases  int    `json:"cases"`
	Reason string `json:"reason"`
}

// CaseSkip is a case not attempted inside an attempted file.
type CaseSkip struct {
	File    string `json:"file"`
	Section string `json:"section"`
	Name    string `json:"name"`
	Reason  string `json:"reason"`
}

// CaseFailure is an attempted case that disagreed with the corpus.
type CaseFailure struct {
	File    string `json:"file"`
	Section string `json:"section"`
	Name    string `json:"name"`
	Detail  string `json:"detail"`
}

// Divergence is a case the two implementations judge differently.
// Since cel4postgres follows the corpus wherever the two disagree
// (docs/CONFORMANCE.md), these are almost always cases cel-go
// itself does not satisfy -- which is exactly what a reader comparing
// the two needs told.
type Divergence struct {
	File         string `json:"file"`
	Section      string `json:"section"`
	Name         string `json:"name"`
	Expr         string `json:"expr"`
	Cel4Postgres string `json:"cel4postgres"`
	CelGo        string `json:"cel_go"`
}

// Build runs every in-scope corpus case against the database and
// against cel-go, and assembles the report.
func Build(ctx context.Context, conn *pgx.Conn) (Report, error) {
	version, err := postgresVersion(ctx, conn)
	if err != nil {
		return Report{}, err
	}

	stages, err := InstalledStages(ctx, conn)
	if err != nil {
		return Report{}, err
	}

	files, err := corpus.Files()
	if err != nil {
		return Report{}, err
	}

	report := Report{
		CelSpec:  corpus.Pin,
		CelGo:    oracle.Version,
		Postgres: version,
	}
	report.Totals.Files = len(files)

	for _, file := range files {
		parsed, err := corpus.Load(file)
		if err != nil {
			return Report{}, err
		}

		cases := 0
		for _, section := range parsed.GetSection() {
			cases += len(section.GetTest())
		}
		report.Totals.Cases += cases

		if reason, ok := SkippedFiles[file]; ok {
			report.SkippedFiles = append(report.SkippedFiles, FileSkip{
				Name: file, Cases: cases, Reason: reason,
			})
			report.Totals.SkippedFiles++
			report.Totals.Skipped += cases
			continue
		}

		summary := FileReport{
			Name: file, Env: EnvFor(file), Cases: cases,
		}

		for _, section := range parsed.GetSection() {
			for _, tc := range section.GetTest() {
				name := section.GetName()
				got := RunCase(ctx, conn, stages, file, name, tc)

				switch got.Status {
				case Skipped:
					summary.Skipped++
					report.SkippedCases = append(
						report.SkippedCases,
						CaseSkip{
							File: file, Section: name,
							Name: tc.GetName(), Reason: got.Detail,
						},
					)
					continue
				case Failed:
					summary.Failed++
					report.Failures = append(report.Failures, CaseFailure{
						File: file, Section: name,
						Name: tc.GetName(), Detail: got.Detail,
					})
				default:
					summary.Passed++
				}

				reference := RunOracleCase(file, name, tc)
				if reference.Status == got.Status {
					continue
				}
				report.Divergences = append(report.Divergences, Divergence{
					File: file, Section: name, Name: tc.GetName(),
					Expr:         tc.GetExpr(),
					Cel4Postgres: verdict(got),
					CelGo:        verdict(reference),
				})
			}
		}

		report.Totals.Passed += summary.Passed
		report.Totals.Skipped += summary.Skipped
		report.Totals.Failed += summary.Failed
		report.Files = append(report.Files, summary)
	}

	sort.Slice(report.SkippedFiles, func(i, j int) bool {
		return report.SkippedFiles[i].Name < report.SkippedFiles[j].Name
	})

	return report, nil
}

// verdict renders one side's outcome for the divergence list.
func verdict(result CaseResult) string {
	if result.Status == Passed {
		return "matches the corpus"
	}
	return "disagrees: " + oneLine(result.Detail)
}

// oneLine flattens a multi-line failure detail so it fits a table
// cell and a JSON field without carrying layout with it.
func oneLine(s string) string {
	fields := strings.Fields(strings.ReplaceAll(s, "\n", " "))
	return strings.Join(fields, " ")
}

// postgresVersion returns the server's major version. The major is
// what can plausibly change a result; a patch release cannot, and
// recording it would churn the report for nothing.
func postgresVersion(ctx context.Context, conn *pgx.Conn) (string, error) {
	var num int
	err := conn.QueryRow(ctx,
		"SELECT current_setting('server_version_num')::int",
	).Scan(&num)
	if err != nil {
		return "", fmt.Errorf("read server version: %w", err)
	}
	return fmt.Sprintf("%d", num/10000), nil
}

// MarshalJSON renders the machine-readable sidecar.
func (r Report) MarshalJSONReport() ([]byte, error) {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}
