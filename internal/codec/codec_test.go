package codec

import (
	"encoding/json"
	"math"
	"testing"

	expr "cel.dev/expr"
)

func decode(t *testing.T, s string) any {
	t.Helper()
	v, err := Decode([]byte(s))
	if err != nil {
		t.Fatalf("decode %s: %v", s, err)
	}
	return v
}

// Conversions round-trip through JSON exactly the way the runner uses
// them: convert the proto, marshal, decode, compare.
func TestFromValueRoundTrip(t *testing.T) {
	cases := []struct {
		name  string
		value *expr.Value
		want  string
	}{
		{
			"int64 min",
			&expr.Value{Kind: &expr.Value_Int64Value{
				Int64Value: math.MinInt64,
			}},
			`{"@t":"int","v":-9223372036854775808}`,
		},
		{
			"uint64 max",
			&expr.Value{Kind: &expr.Value_Uint64Value{
				Uint64Value: math.MaxUint64,
			}},
			`{"@t":"uint","v":18446744073709551615}`,
		},
		{
			"negative infinity",
			&expr.Value{Kind: &expr.Value_DoubleValue{
				DoubleValue: math.Inf(-1),
			}},
			`{"@t":"double","v":"-Infinity"}`,
		},
		{
			"bytes",
			&expr.Value{Kind: &expr.Value_BytesValue{
				BytesValue: []byte("ab"),
			}},
			`{"@t":"bytes","v":"YWI="}`,
		},
		{
			"null",
			&expr.Value{Kind: &expr.Value_NullValue{}},
			`{"@t":"null","v":null}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tagged, err := FromValue(tc.value)
			if err != nil {
				t.Fatal(err)
			}
			got, err := json.Marshal(tagged)
			if err != nil {
				t.Fatal(err)
			}
			if !Equal(decode(t, tc.want), decode(t, string(got))) {
				t.Errorf("got %s, want %s", got, tc.want)
			}
		})
	}
}

func TestEqual(t *testing.T) {
	cases := []struct {
		name  string
		want  string
		got   string
		equal bool
	}{
		{
			"NaN matches NaN",
			`{"@t":"double","v":"NaN"}`, `{"@t":"double","v":"NaN"}`,
			true,
		},
		{
			"kinds never cross",
			`{"@t":"int","v":1}`, `{"@t":"uint","v":1}`,
			false,
		},
		{
			"double never matches int",
			`{"@t":"double","v":1}`, `{"@t":"int","v":1}`,
			false,
		},
		{
			"map entry order is irrelevant",
			`{"@t":"map","v":[
				{"k":{"@t":"string","v":"a"},"v":{"@t":"int","v":1}},
				{"k":{"@t":"string","v":"b"},"v":{"@t":"int","v":2}}]}`,
			`{"@t":"map","v":[
				{"k":{"@t":"string","v":"b"},"v":{"@t":"int","v":2}},
				{"k":{"@t":"string","v":"a"},"v":{"@t":"int","v":1}}]}`,
			true,
		},
		{
			"map sizes must match",
			`{"@t":"map","v":[]}`,
			`{"@t":"map","v":[
				{"k":{"@t":"int","v":1},"v":{"@t":"int","v":1}}]}`,
			false,
		},
		{
			"list order matters",
			`{"@t":"list","v":[{"@t":"int","v":1},{"@t":"int","v":2}]}`,
			`{"@t":"list","v":[{"@t":"int","v":2},{"@t":"int","v":1}]}`,
			false,
		},
		{
			"error matches on existence only",
			`{"@t":"error","v":{"msg":"foo"}}`,
			`{"@t":"error","v":{"msg":"divide by zero","id":3}}`,
			true,
		},
		{
			"timestamp compares by instant, not offset",
			`{"@t":"timestamp","v":{"s":60,"n":5,"tz":0}}`,
			`{"@t":"timestamp","v":{"s":60,"n":5,"tz":-480}}`,
			true,
		},
		{
			"timestamp nanos matter",
			`{"@t":"timestamp","v":{"s":60,"n":5,"tz":0}}`,
			`{"@t":"timestamp","v":{"s":60,"n":6,"tz":0}}`,
			false,
		},
		{
			"int64 extremes compare exactly",
			`{"@t":"int","v":9223372036854775807}`,
			`{"@t":"int","v":9223372036854775806}`,
			false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Equal(decode(t, tc.want), decode(t, tc.got))
			if got != tc.equal {
				t.Errorf("Equal = %v, want %v", got, tc.equal)
			}
		})
	}
}

func TestFromTypeWellKnownNormalization(t *testing.T) {
	converted, err := FromType(&expr.Type{
		TypeKind: &expr.Type_MessageType{
			MessageType: "google.protobuf.Int32Value",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.Marshal(converted)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"kind":"wrapper","params":[{"kind":"int"}]}`
	if string(got) != want {
		t.Errorf("got %s, want %s", got, want)
	}
}
