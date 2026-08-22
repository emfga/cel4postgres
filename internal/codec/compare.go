package codec

import (
	"encoding/json"
	"math"
	"strconv"
)

// Equal compares two tagged values structurally, with the two
// relaxations the conformance comparison requires (workspace doc 08):
// map entries are order-agnostic, and NaN matches NaN (the spec's
// rule; cel-go's own harness lacks it, ours has it). Kinds must match
// exactly -- an int result never equals a uint or double expectation,
// because result identity is what the tag exists to carry.
//
// Timestamps compare by instant (seconds and nanos): the tz field is
// display metadata carried by the value, and a corpus expectation is
// always UTC while an evaluated literal may keep its source offset.
func Equal(want, got any) bool {
	wantKind, wantPayload, ok := split(want)
	if !ok {
		return false
	}
	gotKind, gotPayload, ok := split(got)
	if !ok || wantKind != gotKind {
		return false
	}

	switch wantKind {
	case "null":
		return true
	case "bool":
		w, okW := wantPayload.(bool)
		g, okG := gotPayload.(bool)
		return okW && okG && w == g
	case "int":
		return intEqual(wantPayload, gotPayload)
	case "uint":
		return uintEqual(wantPayload, gotPayload)
	case "double":
		return doubleEqual(wantPayload, gotPayload)
	case "string", "bytes", "type":
		w, okW := wantPayload.(string)
		g, okG := gotPayload.(string)
		return okW && okG && w == g
	case "list":
		return listEqual(wantPayload, gotPayload)
	case "map":
		return mapEqual(wantPayload, gotPayload)
	case "timestamp":
		return timestampEqual(wantPayload, gotPayload)
	case "duration":
		return intEqual(wantPayload, gotPayload)
	case "error":
		// Existence only: expected error message text is never
		// compared (the corpus carries deliberately bogus ones).
		return true
	case "unknown":
		return unknownEqual(wantPayload, gotPayload)
	}
	// Opaque and anything future: strict structural equality.
	return deepEqual(wantPayload, gotPayload)
}

// split pulls the kind and payload out of a tagged value.
func split(v any) (string, any, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", nil, false
	}
	kind, ok := m["@t"].(string)
	if !ok {
		return "", nil, false
	}
	return kind, m["v"], true
}

func number(v any) (string, bool) {
	switch n := v.(type) {
	case json.Number:
		return n.String(), true
	case string:
		return n, true
	case float64:
		return strconv.FormatFloat(n, 'g', -1, 64), true
	}
	return "", false
}

func intEqual(want, got any) bool {
	w, okW := number(want)
	g, okG := number(got)
	if !okW || !okG {
		return false
	}
	wi, errW := strconv.ParseInt(w, 10, 64)
	gi, errG := strconv.ParseInt(g, 10, 64)
	return errW == nil && errG == nil && wi == gi
}

func uintEqual(want, got any) bool {
	w, okW := number(want)
	g, okG := number(got)
	if !okW || !okG {
		return false
	}
	wu, errW := strconv.ParseUint(w, 10, 64)
	gu, errG := strconv.ParseUint(g, 10, 64)
	return errW == nil && errG == nil && wu == gu
}

// float pulls a float64 out of a double payload, which is either a
// number or one of the three non-finite sentinel strings.
func float(v any) (float64, bool) {
	switch n := v.(type) {
	case string:
		switch n {
		case "NaN":
			return math.NaN(), true
		case "Infinity":
			return math.Inf(1), true
		case "-Infinity":
			return math.Inf(-1), true
		}
		return 0, false
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	}
	return 0, false
}

func doubleEqual(want, got any) bool {
	w, okW := float(want)
	g, okG := float(got)
	if !okW || !okG {
		return false
	}
	if math.IsNaN(w) && math.IsNaN(g) {
		return true
	}
	return w == g
}

func listEqual(want, got any) bool {
	w, okW := want.([]any)
	g, okG := got.([]any)
	if !okW || !okG || len(w) != len(g) {
		return false
	}
	for i := range w {
		if !Equal(w[i], g[i]) {
			return false
		}
	}
	return true
}

func mapEqual(want, got any) bool {
	w, okW := want.([]any)
	g, okG := got.([]any)
	if !okW || !okG || len(w) != len(g) {
		return false
	}

	used := make([]bool, len(g))
	for _, wantEntry := range w {
		we, ok := wantEntry.(map[string]any)
		if !ok {
			return false
		}
		found := false
		for i, gotEntry := range g {
			if used[i] {
				continue
			}
			ge, ok := gotEntry.(map[string]any)
			if !ok {
				return false
			}
			if Equal(we["k"], ge["k"]) && Equal(we["v"], ge["v"]) {
				used[i] = true
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func timestampEqual(want, got any) bool {
	w, okW := want.(map[string]any)
	g, okG := got.(map[string]any)
	return okW && okG &&
		intEqual(w["s"], g["s"]) && intEqual(w["n"], g["n"])
}

func unknownEqual(want, got any) bool {
	w, okW := want.([]any)
	g, okG := got.([]any)
	if !okW || !okG || len(w) != len(g) {
		return false
	}
	// Both sides are sorted, deduped id sets by construction.
	for i := range w {
		if !intEqual(w[i], g[i]) {
			return false
		}
	}
	return true
}

func deepEqual(want, got any) bool {
	w, errW := json.Marshal(want)
	g, errG := json.Marshal(got)
	return errW == nil && errG == nil && string(w) == string(g)
}
