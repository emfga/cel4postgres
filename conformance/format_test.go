package conformance

import (
	"context"
	"fmt"
	"math"
	"math/rand/v2"
	"testing"
	"time"

	"github.com/emfga/cel4postgres/internal/testdb"
)

// string(double) is implemented by cel._double_text, which must match
// Go's %g exactly, because that is what cel-go's string(double) emits
// (common/types/double.go:141, pinned v0.32.0). The workspace ruling
// on I2 committed this test: it fuzzes that claim on every CI run
// rather than trusting a handful of probes -- and its very first run
// proved bare float8::text insufficient (Go switches to scientific
// notation at e+06, Postgres at e+15), which is why the function
// exists. A mismatch here reopens the formatting question with a
// concrete value in hand.
//
// Non-finite values are excluded by design: they never reach the
// Postgres formatter (the evaluator emits +Inf/-Inf/NaN itself from
// the tagged sentinel strings).
func TestStringDoubleFormatParity(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	// A fresh seed every run is the point (continuous fuzzing); the
	// log line is what makes a red run reproducible.
	seed := uint64(time.Now().UnixNano())
	t.Logf("seed %d", seed)
	rng := rand.New(rand.NewPCG(seed, 0))

	const n = 4096
	values := make([]float64, 0, n)
	for len(values) < n {
		v := math.Float64frombits(rng.Uint64())
		if math.IsNaN(v) || math.IsInf(v, 0) {
			continue
		}
		values = append(values, v)
	}
	// The corners the probes covered stay covered, plus the plain-to-
	// scientific boundary the first fuzz run exposed.
	values = append(values,
		0.0, math.Copysign(0, -1), 1.0, 123.456, -4.5e-3,
		1e21, 0.000001, math.MaxFloat64, math.SmallestNonzeroFloat64,
		999999.9, 1e6, 1234567.8, 1e15, 999999999999999.0, 0.0001,
	)

	var formatted []string
	err = conn.QueryRow(ctx,
		"SELECT array_agg(cel._double_text(v) ORDER BY ord) "+
			"FROM unnest($1::float8[]) WITH ORDINALITY AS t(v, ord)",
		values,
	).Scan(&formatted)
	if err != nil {
		t.Fatalf("format via Postgres: %v", err)
	}
	if len(formatted) != len(values) {
		t.Fatalf("Postgres returned %d strings for %d values",
			len(formatted), len(values))
	}

	mismatches := 0
	for i, v := range values {
		want := fmt.Sprintf("%g", v)
		if formatted[i] != want {
			mismatches++
			if mismatches <= 10 {
				t.Errorf("float8 %b (%v): Postgres %q, Go %%g %q",
					v, v, formatted[i], want)
			}
		}
	}
	if mismatches > 10 {
		t.Errorf("%d mismatches in total", mismatches)
	}
}
