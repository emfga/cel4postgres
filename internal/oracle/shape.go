package oracle

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"

	"cel.dev/cel-go/cel"
	celast "cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
)

// ParseShape parses an expression with cel-go and returns its AST as
// the node shape cel4postgres emits (workspace doc 03), without ids
// or source offsets. The parse unit tests diff cel.parse output
// against this, so the two parsers are compared structurally rather
// than by transcription.
func ParseShape(
	expression string, options ...cel.EnvOption,
) (map[string]any, error) {
	env, err := Env(options...)
	if err != nil {
		return nil, err
	}

	ast, issues := env.Parse(expression)
	if issues != nil && issues.Err() != nil {
		return nil, fmt.Errorf("parse %q: %w", expression, issues.Err())
	}

	return exprShape(ast.NativeRep().Expr())
}

func exprShape(e celast.Expr) (map[string]any, error) {
	switch e.Kind() {
	case celast.LiteralKind:
		tagged, err := literalShape(e.AsLiteral())
		if err != nil {
			return nil, err
		}
		return map[string]any{"k": "lit", "v": tagged}, nil

	case celast.IdentKind:
		return map[string]any{"k": "ident", "name": e.AsIdent()}, nil

	case celast.SelectKind:
		sel := e.AsSelect()
		op, err := exprShape(sel.Operand())
		if err != nil {
			return nil, err
		}
		shape := map[string]any{
			"k": "select", "op": op, "field": sel.FieldName(),
		}
		if sel.IsTestOnly() {
			shape["test"] = true
		}
		return shape, nil

	case celast.CallKind:
		call := e.AsCall()
		args := []any{}
		for _, a := range call.Args() {
			shape, err := exprShape(a)
			if err != nil {
				return nil, err
			}
			args = append(args, shape)
		}
		shape := map[string]any{
			"k": "call", "fn": call.FunctionName(), "args": args,
		}
		if call.IsMemberFunction() {
			target, err := exprShape(call.Target())
			if err != nil {
				return nil, err
			}
			shape["target"] = target
		}
		return shape, nil

	case celast.ListKind:
		list := e.AsList()
		elems := []any{}
		for _, el := range list.Elements() {
			shape, err := exprShape(el)
			if err != nil {
				return nil, err
			}
			elems = append(elems, shape)
		}
		shape := map[string]any{"k": "list", "elems": elems}
		if len(list.OptionalIndices()) > 0 {
			opt := []any{}
			for _, i := range list.OptionalIndices() {
				opt = append(opt, int64(i))
			}
			shape["opt"] = opt
		}
		return shape, nil

	case celast.MapKind:
		m := e.AsMap()
		entries := []any{}
		for _, entry := range m.Entries() {
			me := entry.AsMapEntry()
			k, err := exprShape(me.Key())
			if err != nil {
				return nil, err
			}
			v, err := exprShape(me.Value())
			if err != nil {
				return nil, err
			}
			entries = append(entries, map[string]any{
				"k": k, "v": v, "opt": me.IsOptional(),
			})
		}
		return map[string]any{"k": "map", "entries": entries}, nil

	case celast.StructKind:
		s := e.AsStruct()
		fields := []any{}
		for _, field := range s.Fields() {
			sf := field.AsStructField()
			v, err := exprShape(sf.Value())
			if err != nil {
				return nil, err
			}
			fields = append(fields, map[string]any{
				"name": sf.Name(), "v": v, "opt": sf.IsOptional(),
			})
		}
		return map[string]any{
			"k": "struct", "type": s.TypeName(), "fields": fields,
		}, nil

	case celast.ComprehensionKind:
		comp := e.AsComprehension()
		shape := map[string]any{
			"k":     "comp",
			"iter":  comp.IterVar(),
			"iter2": "",
			"accu":  comp.AccuVar(),
		}
		if comp.HasIterVar2() {
			shape["iter2"] = comp.IterVar2()
		}
		for key, sub := range map[string]celast.Expr{
			"range": comp.IterRange(), "init": comp.AccuInit(),
			"cond": comp.LoopCondition(), "step": comp.LoopStep(),
			"result": comp.Result(),
		} {
			converted, err := exprShape(sub)
			if err != nil {
				return nil, err
			}
			shape[key] = converted
		}
		return shape, nil
	}
	return nil, fmt.Errorf("unsupported expr kind %v", e.Kind())
}

// literalShape renders a cel-go constant as a tagged value, with
// payloads matching internal/codec's conventions.
func literalShape(v ref.Val) (map[string]any, error) {
	switch value := v.(type) {
	case types.Bool:
		return map[string]any{"@t": "bool", "v": bool(value)}, nil
	case types.Int:
		return map[string]any{
			"@t": "int", "v": json.Number(strconv.FormatInt(int64(value), 10)),
		}, nil
	case types.Uint:
		return map[string]any{
			"@t": "uint", "v": json.Number(strconv.FormatUint(uint64(value), 10)),
		}, nil
	case types.Double:
		return map[string]any{"@t": "double", "v": float64(value)}, nil
	case types.String:
		return map[string]any{"@t": "string", "v": string(value)}, nil
	case types.Bytes:
		return map[string]any{
			"@t": "bytes",
			"v":  base64.StdEncoding.EncodeToString([]byte(value)),
		}, nil
	case types.Null:
		return map[string]any{"@t": "null", "v": nil}, nil
	}
	return nil, fmt.Errorf("unsupported literal %T", v)
}
