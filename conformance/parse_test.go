package conformance

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	"github.com/emfga/cel4postgres/internal/oracle"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// The curated list the parser is diffed against cel-go on. Coverage,
// not volume: every node kind, every operator tier, every macro, the
// normalizations (sign folding, chain collapsing, && || rebalancing)
// and the syntax corners the corpus leans on.
var parseShapeExprs = []string{
	// Literals.
	"0", "42", "-1", "0x1F", "-0x1F", "18446744073709551615u", "0xFFu",
	"1.5", "-1.5", ".5", "1e3", "-2.5e-2", "9223372036854775807",
	"-9223372036854775808",
	"true", "false", "null",
	`"hi"`, `'wörld'`, `"tab\tnewline\n"`, `r'raw\n'`, `b'bytes\xff'`,
	`'''triple " quote'''`,
	// Operators, precedence, associativity.
	"1 + 2 * 3 - 4 / 5 % 6",
	"a || b && c || d && e",
	"a || b || c || d || e",
	"a && b && c && d && e",
	"1 < 2 <= 3 > 4 >= 5 == 6 != 7",
	"x in [1, 2]",
	"a ? b : c ? d : e",
	"(a ? b : c) ? d : e",
	"!a", "!!a", "!!!a", "-a", "--a", "---a", "-(5)",
	// Member/postfix.
	"a.b.c", "a[0]", "a.b[c.d].e", "a.b(c)", "a.b(c, d).e(f)",
	"f()", "f(1)", "f(1, 2)", ".g(h)", ".a.b",
	// Aggregates.
	"[]", "[1]", "[1, 2u, 3.0]", "[1, 2,]",
	"{}", "{'a': 1}", "{1: 'a', 2u: b, c: d,}",
	"Msg{}", "Msg{a: 1}", "pkg.Msg{a: 1, b: 2,}", ".pkg.Msg{a: 1}",
	// Macros.
	"has(a.b)", "has(a.b.c)",
	"[1, 2].all(x, x > 0)",
	"[1, 2].exists(x, x > 1)",
	"[1, 2].exists_one(x, x == 1)",
	"[1, 2].map(x, x * 2)",
	"[1, 2].map(x, x > 0, x * 2)",
	"[1, 2].filter(x, x > 1)",
	"{'a': 1}.all(k, k == 'a')",
	"[[1], [2]].all(l, l.all(x, x > 0))",
	// Non-macro calls with macro names but wrong arity/receiver.
	"all(1, 2)", "x.has(y)",
	// Escaped identifiers (standard enables the syntax).
	"a.`b-c`", "a.`b c`.d", "Msg{`f-1`: 2}",
	// Whitespace and comments.
	"1 + // comment\n 2",
}

// TestParseShape diffs cel.parse against cel-go's parser on the
// curated list, comparing tree shape (kinds, names, values, operator
// functions, macro expansions) while ignoring node ids and offsets,
// which nothing in conformance compares.
func TestParseShape(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	options, err := oracle.Options("standard")
	if err != nil {
		t.Fatal(err)
	}

	for _, expr := range parseShapeExprs {
		t.Run(expr, func(t *testing.T) {
			want, err := oracle.ParseShape(expr, options...)
			if err != nil {
				t.Fatalf("cel-go: %v", err)
			}

			var raw []byte
			err = conn.QueryRow(ctx,
				"SELECT cel.parse($1, 'standard')", expr,
			).Scan(&raw)
			if err != nil {
				t.Fatalf("cel.parse: %v", err)
			}
			var envelope map[string]any
			decoder := json.NewDecoder(bytes.NewReader(raw))
			decoder.UseNumber()
			if err := decoder.Decode(&envelope); err != nil {
				t.Fatal(err)
			}
			if errs, ok := envelope["errors"]; ok {
				t.Fatalf("cel.parse rejected: %v", errs)
			}

			got := stripIDs(envelope["expr"])
			if !shapeEqual(normalize(want), got) {
				wantJSON, _ := json.MarshalIndent(normalize(want), "", "  ")
				gotJSON, _ := json.MarshalIndent(got, "", "  ")
				t.Errorf("shape mismatch\ncel-go:\n%s\ncel.parse:\n%s",
					wantJSON, gotJSON)
			}
		})
	}
}

// TestParseErrorsRejected checks that expressions cel-go rejects are
// rejected by cel.parse too (message text is not compared).
func TestParseErrorsRejected(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	exprs := []string{
		"1 +", "(1", "[1", "{1: ", "a.", "a[1", "f(", "1 2",
		"while", "var", "1.е3", "'unterminated", `"\z"`, `"\x1"`,
		"9223372036854775808", "-9223372036854775809",
		"18446744073709551616u", "?:", "a ? b", "in", ".", "..a",
		"x.?y", "[?x]", "{?'k': v}", "'\\'", "b\"abc",
		// Escaped identifiers are not primaries.
		"`a`.b",
	}

	for _, expr := range exprs {
		t.Run(expr, func(t *testing.T) {
			var raw []byte
			err := conn.QueryRow(ctx,
				"SELECT cel.parse($1, 'standard')", expr,
			).Scan(&raw)
			if err != nil {
				t.Fatalf("cel.parse errored at the SQL level: %v", err)
			}
			var envelope map[string]any
			if err := json.Unmarshal(raw, &envelope); err != nil {
				t.Fatal(err)
			}
			if _, ok := envelope["errors"]; !ok {
				t.Fatalf("cel.parse accepted %q: %s", expr, raw)
			}
		})
	}
}

// stripIDs removes "id" keys recursively; ids carry no comparable
// meaning across the two parsers.
func stripIDs(v any) any {
	switch value := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, sub := range value {
			if k == "id" {
				continue
			}
			out[k] = stripIDs(sub)
		}
		return out
	case []any:
		out := make([]any, len(value))
		for i, sub := range value {
			out[i] = stripIDs(sub)
		}
		return out
	}
	return v
}

// normalize round-trips the oracle shape through JSON so both sides
// carry json.Number for numbers.
func normalize(v any) any {
	data, err := json.Marshal(v)
	if err != nil {
		return v
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var out any
	if err := decoder.Decode(&out); err != nil {
		return v
	}
	return out
}

// shapeEqual compares two JSON trees, with numbers compared
// numerically (int64 exactly, doubles by value).
func shapeEqual(want, got any) bool {
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok || len(w) != len(g) {
			return false
		}
		for k, wv := range w {
			gv, ok := g[k]
			if !ok || !shapeEqual(wv, gv) {
				return false
			}
		}
		return true
	case []any:
		g, ok := got.([]any)
		if !ok || len(w) != len(g) {
			return false
		}
		for i := range w {
			if !shapeEqual(w[i], g[i]) {
				return false
			}
		}
		return true
	case json.Number:
		g, ok := got.(json.Number)
		if !ok {
			return false
		}
		if wi, err := w.Int64(); err == nil {
			if gi, err := g.Int64(); err == nil {
				return wi == gi
			}
		}
		wf, errW := w.Float64()
		gf, errG := g.Float64()
		return errW == nil && errG == nil && wf == gf
	case string:
		g, ok := got.(string)
		return ok && w == g
	}
	return want == got
}
