package codec

import (
	"fmt"

	expr "cel.dev/expr"
)

// TypeJSON is the type encoding of workspace doc 03, used in checked
// ASTs, registry rows and declarations.
type TypeJSON = map[string]any

func kindOnly(kind string) TypeJSON {
	return TypeJSON{"kind": kind}
}

var primitiveKinds = map[expr.Type_PrimitiveType]string{
	expr.Type_BOOL:   "bool",
	expr.Type_INT64:  "int",
	expr.Type_UINT64: "uint",
	expr.Type_DOUBLE: "double",
	expr.Type_STRING: "string",
	expr.Type_BYTES:  "bytes",
}

// wellKnownMessages normalizes well-known message names exactly as
// cel-go's checkedWellKnowns does at declaration time (workspace doc
// 03; cel-go common/types.go:834).
var wellKnownMessages = map[string]TypeJSON{
	"google.protobuf.Timestamp": kindOnly("timestamp"),
	"google.protobuf.Duration":  kindOnly("duration"),
	"google.protobuf.Any":       kindOnly("any"),
	"google.protobuf.NullValue": kindOnly("null"),
	"google.protobuf.Value":     kindOnly("dyn"),
	"google.protobuf.Struct": {
		"kind":   "map",
		"params": []any{kindOnly("string"), kindOnly("dyn")},
	},
	"google.protobuf.ListValue": {
		"kind": "list", "params": []any{kindOnly("dyn")},
	},
	"google.protobuf.BoolValue": {
		"kind": "wrapper", "params": []any{kindOnly("bool")},
	},
	"google.protobuf.Int32Value": {
		"kind": "wrapper", "params": []any{kindOnly("int")},
	},
	"google.protobuf.Int64Value": {
		"kind": "wrapper", "params": []any{kindOnly("int")},
	},
	"google.protobuf.UInt32Value": {
		"kind": "wrapper", "params": []any{kindOnly("uint")},
	},
	"google.protobuf.UInt64Value": {
		"kind": "wrapper", "params": []any{kindOnly("uint")},
	},
	"google.protobuf.FloatValue": {
		"kind": "wrapper", "params": []any{kindOnly("double")},
	},
	"google.protobuf.DoubleValue": {
		"kind": "wrapper", "params": []any{kindOnly("double")},
	},
	"google.protobuf.StringValue": {
		"kind": "wrapper", "params": []any{kindOnly("string")},
	},
	"google.protobuf.BytesValue": {
		"kind": "wrapper", "params": []any{kindOnly("bytes")},
	},
}

// FromType converts a checked.proto Type to the type-json encoding.
func FromType(t *expr.Type) (TypeJSON, error) {
	switch kind := t.GetTypeKind().(type) {
	case *expr.Type_Dyn:
		return kindOnly("dyn"), nil
	case *expr.Type_Null:
		return kindOnly("null"), nil
	case *expr.Type_Primitive:
		name, ok := primitiveKinds[kind.Primitive]
		if !ok {
			return nil, fmt.Errorf("primitive type %v", kind.Primitive)
		}
		return kindOnly(name), nil
	case *expr.Type_Wrapper:
		name, ok := primitiveKinds[kind.Wrapper]
		if !ok {
			return nil, fmt.Errorf("wrapper of %v", kind.Wrapper)
		}
		return TypeJSON{
			"kind": "wrapper", "params": []any{kindOnly(name)},
		}, nil
	case *expr.Type_WellKnown:
		switch kind.WellKnown {
		case expr.Type_ANY:
			return kindOnly("any"), nil
		case expr.Type_TIMESTAMP:
			return kindOnly("timestamp"), nil
		case expr.Type_DURATION:
			return kindOnly("duration"), nil
		}
		return nil, fmt.Errorf("well-known type %v", kind.WellKnown)
	case *expr.Type_ListType_:
		elem, err := FromType(kind.ListType.GetElemType())
		if err != nil {
			return nil, err
		}
		return TypeJSON{"kind": "list", "params": []any{elem}}, nil
	case *expr.Type_MapType_:
		key, err := FromType(kind.MapType.GetKeyType())
		if err != nil {
			return nil, err
		}
		value, err := FromType(kind.MapType.GetValueType())
		if err != nil {
			return nil, err
		}
		return TypeJSON{"kind": "map", "params": []any{key, value}}, nil
	case *expr.Type_Type:
		if kind.Type == nil || kind.Type.GetTypeKind() == nil {
			return kindOnly("type"), nil
		}
		param, err := FromType(kind.Type)
		if err != nil {
			return nil, err
		}
		return TypeJSON{"kind": "type", "params": []any{param}}, nil
	case *expr.Type_MessageType:
		if wellKnown, ok := wellKnownMessages[kind.MessageType]; ok {
			return wellKnown, nil
		}
		return TypeJSON{"kind": "struct", "name": kind.MessageType}, nil
	case *expr.Type_TypeParam:
		return TypeJSON{"kind": "param", "name": kind.TypeParam}, nil
	case *expr.Type_Error:
		return kindOnly("error"), nil
	case *expr.Type_AbstractType_:
		params := []any{}
		for _, p := range kind.AbstractType.GetParameterTypes() {
			converted, err := FromType(p)
			if err != nil {
				return nil, err
			}
			params = append(params, converted)
		}
		return TypeJSON{
			"kind":   "opaque",
			"name":   kind.AbstractType.GetName(),
			"params": params,
		}, nil
	}
	return nil, fmt.Errorf("type with unsupported kind %T", t.GetTypeKind())
}

// FromDecl converts a type_env declaration to the {name, type} shape
// cel.check's options parameter takes. Every corpus declaration is an
// ident declaration (measured, workspace doc 01); a function decl here
// means the corpus changed and the runner needs extending.
func FromDecl(d *expr.Decl) (map[string]any, error) {
	ident := d.GetIdent()
	if ident == nil {
		return nil, fmt.Errorf(
			"declaration %q is not an ident declaration", d.GetName(),
		)
	}

	declType, err := FromType(ident.GetType())
	if err != nil {
		return nil, fmt.Errorf("declaration %q: %w", d.GetName(), err)
	}

	return map[string]any{"name": d.GetName(), "type": declType}, nil
}
