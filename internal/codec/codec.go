// Package codec converts between the conformance corpus's protobuf
// value/type messages and the tagged-jsonb representation cel4postgres
// uses (workspace docs 02 and 03: tag key "@t", maps as entry arrays,
// timestamps as {s, n, tz}, non-finite doubles as strings).
//
// Numbers are carried as json.Number end to end so int64/uint64
// payloads never pass through a float64.
package codec

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"

	expr "cel.dev/expr"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// Tagged is one CEL value in the tagged-jsonb shape.
type Tagged = map[string]any

func tag(kind string, payload any) Tagged {
	return Tagged{"@t": kind, "v": payload}
}

func intNum(v int64) json.Number {
	return json.Number(strconv.FormatInt(v, 10))
}

func uintNum(v uint64) json.Number {
	return json.Number(strconv.FormatUint(v, 10))
}

// doublePayload renders a float64 the way the value spec requires:
// non-finite values as the three sentinel strings, finite values as a
// shortest-round-trip number.
func doublePayload(v float64) any {
	switch {
	case math.IsNaN(v):
		return "NaN"
	case math.IsInf(v, 1):
		return "Infinity"
	case math.IsInf(v, -1):
		return "-Infinity"
	}
	return json.Number(strconv.FormatFloat(v, 'g', -1, 64))
}

// FromExprValue converts a corpus binding or expected result. Errors
// and unknowns are values in this representation (workspace doc 02),
// so all three ExprValue kinds map to a tag.
func FromExprValue(v *expr.ExprValue) (Tagged, error) {
	switch kind := v.GetKind().(type) {
	case *expr.ExprValue_Value:
		return FromValue(kind.Value)
	case *expr.ExprValue_Error:
		msg := ""
		if errs := kind.Error.GetErrors(); len(errs) > 0 {
			msg = errs[0].GetMessage()
		}
		return tag("error", map[string]any{"msg": msg}), nil
	case *expr.ExprValue_Unknown:
		ids := []any{}
		for _, id := range kind.Unknown.GetExprs() {
			ids = append(ids, intNum(id))
		}
		return tag("unknown", ids), nil
	}
	return nil, fmt.Errorf("ExprValue with no kind")
}

// FromValue converts a corpus Value proto to a tagged value.
func FromValue(v *expr.Value) (Tagged, error) {
	switch kind := v.GetKind().(type) {
	case *expr.Value_NullValue:
		return tag("null", nil), nil
	case *expr.Value_BoolValue:
		return tag("bool", kind.BoolValue), nil
	case *expr.Value_Int64Value:
		return tag("int", intNum(kind.Int64Value)), nil
	case *expr.Value_Uint64Value:
		return tag("uint", uintNum(kind.Uint64Value)), nil
	case *expr.Value_DoubleValue:
		return tag("double", doublePayload(kind.DoubleValue)), nil
	case *expr.Value_StringValue:
		return tag("string", kind.StringValue), nil
	case *expr.Value_BytesValue:
		encoded := base64.StdEncoding.EncodeToString(kind.BytesValue)
		return tag("bytes", encoded), nil
	case *expr.Value_TypeValue:
		return tag("type", kind.TypeValue), nil
	case *expr.Value_ListValue:
		elems := []any{}
		for _, e := range kind.ListValue.GetValues() {
			tagged, err := FromValue(e)
			if err != nil {
				return nil, err
			}
			elems = append(elems, tagged)
		}
		return tag("list", elems), nil
	case *expr.Value_MapValue:
		entries := []any{}
		for _, e := range kind.MapValue.GetEntries() {
			k, err := FromValue(e.GetKey())
			if err != nil {
				return nil, err
			}
			val, err := FromValue(e.GetValue())
			if err != nil {
				return nil, err
			}
			entries = append(entries, map[string]any{"k": k, "v": val})
		}
		return tag("map", entries), nil
	case *expr.Value_ObjectValue:
		message, err := kind.ObjectValue.UnmarshalNew()
		if err != nil {
			return nil, fmt.Errorf(
				"unpack Any %q: requires protobuf descriptors (%w)",
				kind.ObjectValue.GetTypeUrl(), err,
			)
		}
		return fromWellKnown(message)
	case *expr.Value_EnumValue:
		return nil, fmt.Errorf("enum values require protobuf descriptors")
	}
	return nil, fmt.Errorf("Value with no kind")
}

// fromWellKnown converts the well-known-type messages that are in
// scope without a descriptor pool (decision 3). Anything else is a
// descriptor-dependent case the skip list already names.
func fromWellKnown(message any) (Tagged, error) {
	switch m := message.(type) {
	case *timestamppb.Timestamp:
		// Proto timestamps are UTC by definition, hence offset 0.
		return tag("timestamp", map[string]any{
			"s":  intNum(m.GetSeconds()),
			"n":  intNum(int64(m.GetNanos())),
			"tz": intNum(0),
		}), nil
	case *durationpb.Duration:
		nanos := m.GetSeconds()*1_000_000_000 + int64(m.GetNanos())
		return tag("duration", intNum(nanos)), nil
	case *wrapperspb.BoolValue:
		return tag("bool", m.GetValue()), nil
	case *wrapperspb.Int32Value:
		return tag("int", intNum(int64(m.GetValue()))), nil
	case *wrapperspb.Int64Value:
		return tag("int", intNum(m.GetValue())), nil
	case *wrapperspb.UInt32Value:
		return tag("uint", uintNum(uint64(m.GetValue()))), nil
	case *wrapperspb.UInt64Value:
		return tag("uint", uintNum(m.GetValue())), nil
	case *wrapperspb.FloatValue:
		return tag("double", doublePayload(float64(m.GetValue()))), nil
	case *wrapperspb.DoubleValue:
		return tag("double", doublePayload(m.GetValue())), nil
	case *wrapperspb.StringValue:
		return tag("string", m.GetValue()), nil
	case *wrapperspb.BytesValue:
		encoded := base64.StdEncoding.EncodeToString(m.GetValue())
		return tag("bytes", encoded), nil
	case *structpb.Value:
		return fromJSON(m), nil
	case *structpb.Struct:
		return fromJSONStruct(m), nil
	case *structpb.ListValue:
		return fromJSONList(m), nil
	}
	return nil, fmt.Errorf(
		"object value %T requires protobuf descriptors", message,
	)
}

// fromJSON applies google.protobuf.Value semantics: JSON numbers are
// CEL doubles, objects are map(string, dyn), arrays are list(dyn).
func fromJSON(v *structpb.Value) Tagged {
	switch kind := v.GetKind().(type) {
	case *structpb.Value_NullValue, nil:
		return tag("null", nil)
	case *structpb.Value_BoolValue:
		return tag("bool", kind.BoolValue)
	case *structpb.Value_NumberValue:
		return tag("double", doublePayload(kind.NumberValue))
	case *structpb.Value_StringValue:
		return tag("string", kind.StringValue)
	case *structpb.Value_StructValue:
		return fromJSONStruct(kind.StructValue)
	case *structpb.Value_ListValue:
		return fromJSONList(kind.ListValue)
	}
	return tag("null", nil)
}

func fromJSONStruct(s *structpb.Struct) Tagged {
	// Field order in a proto map is nondeterministic; sort so the
	// conversion is stable. Comparison is order-agnostic anyway.
	fields := s.GetFields()
	names := make([]string, 0, len(fields))
	for name := range fields {
		names = append(names, name)
	}
	sort.Strings(names)

	entries := []any{}
	for _, name := range names {
		entries = append(entries, map[string]any{
			"k": tag("string", name),
			"v": fromJSON(fields[name]),
		})
	}
	return tag("map", entries)
}

func fromJSONList(l *structpb.ListValue) Tagged {
	elems := []any{}
	for _, e := range l.GetValues() {
		elems = append(elems, fromJSON(e))
	}
	return tag("list", elems)
}

// Marshal renders a tagged value as JSON for sending to Postgres.
func Marshal(v Tagged) ([]byte, error) {
	return json.Marshal(v)
}

// Decode parses JSON returned by Postgres, keeping numbers as
// json.Number so int64/uint64 payloads survive exactly.
func Decode(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()

	var v any
	if err := decoder.Decode(&v); err != nil {
		return nil, fmt.Errorf("decode tagged value: %w", err)
	}
	return v, nil
}
