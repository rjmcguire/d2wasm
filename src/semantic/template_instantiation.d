/**
 * Template Instantiation Driver
 *
 * Handles instantiation of templates (functions, structs, etc.) by re-parsing
 * the template's source text for each unique type argument combination. This
 * produces completely fresh, independent AST nodes for each instantiation —
 * no shared mutable state between different instantiations.
 *
 * Both `T max(T)(T a, T b) { ... }` and `struct Pair(T, U) { ... }` are
 * eponymous template shorthands — the parser wraps them in TemplateDecl,
 * and this module instantiates them uniformly.
 */
module semantic.template_instantiation;

import ast.nodes;
import ast.statements;
import ast.expressions;
import std.array : join;
import std.format : format;

/// A single template argument — can be a type, an expression (value), or both
/// (for ambiguous identifiers resolved by the type checker).
/// Generalizable to alias/sequence params in the future.
struct TemplateArg {
    Type type;       // non-null for type args (e.g., T → int)
    Expression expr; // non-null for value args (e.g., N → LiteralExpression(5))
    // Future: Declaration decl; for alias params
    // Future: TemplateArg[] seq; for sequence params
}

class TemplateInstantiator {
    private Declaration[string] cache;

    /// Delegate for evaluating template constraints via CTFE.
    /// Throws on failure (TypeError if constraint not satisfied, or CTFE error).
    void delegate(Expression, SourceLocation, string, string[]) constraintEvaluator;

    /// Language-agnostic parse delegate — set by TypeChecker from SymbolTable.
    import parser.source_parser : ParseFn;
    ParseFn parseFn;

    /// Instantiate a template for given arguments (unified type + value).
    /// Returns the eponymous member Declaration (FunctionDecl, StructDecl, etc.).
    Declaration instantiate(TemplateDecl tmpl, TemplateArg[] args) {
        string key = mangleInstantiation(tmpl.name, args);
        if (auto cached = key in cache)
            return *cached;

        auto inst = reparseAndSubstitute(tmpl, args, key);
        cache[key] = inst;
        return inst;
    }

    /// Legacy overload: type-only args (for backward compat with existing callers).
    Declaration instantiate(TemplateDecl tmpl, Type[] typeArgs) {
        TemplateArg[] args;
        foreach (t; typeArgs)
            args ~= TemplateArg(t, null);
        return instantiate(tmpl, args);
    }

    /// Get all cached instantiations (for emitter collection).
    Declaration[] allInstantiations() {
        return cache.values;
    }

    /// Re-parse the template source text and substitute concrete types/values.
    private Declaration reparseAndSubstitute(TemplateDecl tmpl, TemplateArg[] args, string mangledName) {
        // Extract source text from the template
        string src = tmpl.getSourceText();
        if (src is null)
            throw new Exception(format("Template '%s' has no stored source text", tmpl.name));

        // Re-parse to get fresh, independent AST
        string syntheticName = "<template:" ~ mangledName ~ ">";
        Declaration[] parsed;
        if (parseFn !is null) {
            parsed = parseFn(syntheticName, src);
        } else {
            import parser.tree_sitter_bridge : TreeSitterBridge;
            auto bridge = new TreeSitterBridge(syntheticName, src);
            parsed = bridge.parseSourceFile();
        }

        // Find the TemplateDecl in the re-parsed result (re-parsing a template produces a TemplateDecl)
        TemplateDecl freshTmpl = null;
        foreach (decl; parsed) {
            if (auto td = cast(TemplateDecl)decl) {
                if (td.name == tmpl.name) {
                    freshTmpl = td;
                    break;
                }
            }
        }
        if (freshTmpl is null)
            throw new Exception(format("Re-parse of template '%s' failed to produce a TemplateDecl", tmpl.name));

        // Build unified substitution map from template params
        TemplateArg[string] substMap;
        foreach (i, tp; tmpl.templateParams) {
            if (i < args.length)
                substMap[tp.paramName] = args[i];
        }

        // Substitute in all members
        foreach (member; freshTmpl.members) {
            substituteInDeclaration(member, substMap);
        }

        // Substitute in constraint and evaluate via CTFE
        if (freshTmpl.constraint !is null) {
            freshTmpl.constraint = substituteInExpression(freshTmpl.constraint, substMap);
            if (constraintEvaluator !is null) {
                string[] bindings;
                foreach (i, tp; tmpl.templateParams) {
                    if (i < args.length) {
                        if (args[i].type !is null)
                            bindings ~= tp.paramName ~ " = " ~ args[i].type.toString();
                        else if (args[i].expr !is null)
                            bindings ~= tp.paramName ~ " = " ~ args[i].expr.toString();
                    }
                }
                constraintEvaluator(freshTmpl.constraint, tmpl.constraint.location,
                                    tmpl.name, bindings);
            }
        }

        // Find and rename the eponymous member
        auto eponymous = freshTmpl.eponymousMember();
        if (eponymous is null)
            throw new Exception(format("Template '%s' has no eponymous member", tmpl.name));

        eponymous.name = mangledName;
        return eponymous;
    }

    static string mangleInstantiation(string templateName, TemplateArg[] args) {
        string[] keys;
        foreach (arg; args) {
            if (arg.type !is null)
                keys ~= typeKey(arg.type);
            else if (arg.expr !is null)
                keys ~= valueKey(arg.expr);
        }
        return templateName ~ "_" ~ keys.join("_");
    }

    /// Legacy overload for type-only mangling.
    static string mangleInstantiation(string templateName, Type[] typeArgs) {
        string[] typeKeys;
        foreach (t; typeArgs)
            typeKeys ~= typeKey(t);
        return templateName ~ "_" ~ typeKeys.join("_");
    }

    static string typeKey(Type t) {
        if (auto bt = cast(BasicType)t) {
            import std.conv : to;
            return bt.kind.to!string;
        }
        if (auto ut = cast(UserType)t)
            return ut.name;
        if (auto tpt = cast(TemplateParamType)t) {
            if (tpt.boundType)
                return typeKey(tpt.boundType);
            return tpt.paramName;
        }
        return t.toString();
    }

    static string valueKey(Expression expr) {
        if (auto lit = cast(LiteralExpression)expr)
            return "V" ~ lit.toString();
        return "V_";
    }
}

// ===== Substitution helpers (unified TemplateArg map) =====

/// Substitute types and values in a declaration (dispatches by declaration kind).
private void substituteInDeclaration(Declaration decl, TemplateArg[string] substMap) {
    if (auto fd = cast(FunctionDecl)decl) {
        fd.returnType = substituteType(fd.returnType, substMap);
        foreach (ref p; fd.parameters)
            p.type = substituteType(p.type, substMap);
        if (fd.body_)
            substituteInStatement(fd.body_, substMap);
    } else if (auto sd = cast(StructDecl)decl) {
        foreach (member; sd.members) {
            substituteInDeclaration(member, substMap);
        }
    } else if (auto vd = cast(VariableDecl)decl) {
        vd.type = substituteType(vd.type, substMap);
    }
}

/// Replace TemplateParamType/UserType nodes matching template params with concrete types.
/// Also substitutes value params in ArrayType.arraySize expressions.
private Type substituteType(Type type, TemplateArg[string] substMap) {
    if (type is null) return null;

    if (auto tpt = cast(TemplateParamType)type) {
        if (auto arg = tpt.paramName in substMap) {
            if (arg.type !is null) return arg.type;
        }
        return type;
    }
    // After re-parsing, template param names in non-signature positions (e.g. __traits args)
    // appear as UserType, not TemplateParamType — substitute those too.
    if (auto ut = cast(UserType)type) {
        if (auto arg = ut.name in substMap) {
            if (arg.type !is null) return arg.type;
        }
        return type;
    }
    if (auto at = cast(ArrayType)type) {
        at.elementType = substituteType(at.elementType, substMap);
        // Substitute value params in array size expression (T[N] → T[5])
        if (at.arraySize !is null)
            at.arraySize = substituteInExpression(at.arraySize, substMap);
        return type;
    }
    if (auto pt = cast(PointerType)type) {
        pt.pointeeType = substituteType(pt.pointeeType, substMap);
        return type;
    }
    return type;
}

/// Walk a statement tree and substitute types and values.
private void substituteInStatement(Statement stmt, TemplateArg[string] substMap) {
    if (stmt is null) return;

    if (auto cs = cast(CompoundStatement)stmt) {
        foreach (s; cs.statements)
            substituteInStatement(s, substMap);
    } else if (auto ifs = cast(IfStatement)stmt) {
        ifs.condition = substituteInExpression(ifs.condition, substMap);
        substituteInStatement(ifs.thenStatement, substMap);
        substituteInStatement(ifs.elseStatement, substMap);
    } else if (auto ws = cast(WhileStatement)stmt) {
        ws.condition = substituteInExpression(ws.condition, substMap);
        substituteInStatement(ws.body_, substMap);
    } else if (auto fs = cast(ForStatement)stmt) {
        substituteInStatement(fs.init, substMap);
        fs.condition = substituteInExpression(fs.condition, substMap);
        fs.update = substituteInExpression(fs.update, substMap);
        substituteInStatement(fs.body_, substMap);
    } else if (auto rs = cast(ReturnStatement)stmt) {
        rs.value = substituteInExpression(rs.value, substMap);
    } else if (auto es = cast(ExpressionStatement)stmt) {
        es.expression = substituteInExpression(es.expression, substMap);
    } else if (auto vds = cast(VariableDeclarationStatement)stmt) {
        vds.type = substituteType(vds.type, substMap);
        vds.initializer = substituteInExpression(vds.initializer, substMap);
    }
}

/// Walk an expression tree and substitute types and values.
/// Returns the (possibly replaced) expression — callers must assign the result.
private Expression substituteInExpression(Expression expr, TemplateArg[string] substMap) {
    if (expr is null) return null;

    // Value param substitution: IdentifierExpression("N") → LiteralExpression(5)
    if (auto ident = cast(IdentifierExpression)expr) {
        if (auto arg = ident.name in substMap) {
            if (arg.expr !is null) return arg.expr;
        }
    }

    if (auto bin = cast(BinaryExpression)expr) {
        bin.left = substituteInExpression(bin.left, substMap);
        bin.right = substituteInExpression(bin.right, substMap);
    } else if (auto un = cast(UnaryExpression)expr) {
        un.operand = substituteInExpression(un.operand, substMap);
    } else if (auto call = cast(CallExpression)expr) {
        call.function_ = substituteInExpression(call.function_, substMap);
        foreach (ref arg; call.arguments)
            arg = substituteInExpression(arg, substMap);
    } else if (auto ti = cast(TemplateInstantiationExpression)expr) {
        foreach (ref targ; ti.templateArguments)
            targ = substituteType(targ, substMap);
        foreach (ref arg; ti.callArguments)
            arg = substituteInExpression(arg, substMap);
    } else if (auto idx = cast(IndexExpression)expr) {
        idx.array = substituteInExpression(idx.array, substMap);
        idx.index = substituteInExpression(idx.index, substMap);
    } else if (auto sl = cast(SliceExpression)expr) {
        sl.array = substituteInExpression(sl.array, substMap);
        sl.start = substituteInExpression(sl.start, substMap);
        sl.end = substituteInExpression(sl.end, substMap);
    } else if (auto mem = cast(MemberExpression)expr) {
        mem.object = substituteInExpression(mem.object, substMap);
    } else if (auto assign = cast(AssignmentExpression)expr) {
        assign.left = substituteInExpression(assign.left, substMap);
        assign.right = substituteInExpression(assign.right, substMap);
    } else if (auto cast_ = cast(CastExpression)expr) {
        cast_.targetType = substituteType(cast_.targetType, substMap);
        cast_.expression = substituteInExpression(cast_.expression, substMap);
    } else if (auto arrLit = cast(ArrayLiteralExpression)expr) {
        foreach (ref elem; arrLit.elements)
            elem = substituteInExpression(elem, substMap);
    } else if (auto traits = cast(TraitsExpression)expr) {
        foreach (ref t; traits.typeArguments)
            t = substituteType(t, substMap);
    } else if (auto isExpr = cast(IsExpression)expr) {
        isExpr.checkedType = substituteType(isExpr.checkedType, substMap);
        if (isExpr.specType !is null)
            isExpr.specType = substituteType(isExpr.specType, substMap);
    }
    return expr;
}
