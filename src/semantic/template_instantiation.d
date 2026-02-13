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

class TemplateInstantiator {
    private Declaration[string] cache;

    /// Delegate for evaluating template constraints via CTFE.
    /// Throws on failure (TypeError if constraint not satisfied, or CTFE error).
    void delegate(Expression, SourceLocation) constraintEvaluator;

    /// Instantiate a template for given type arguments.
    /// Returns the eponymous member Declaration (FunctionDecl, StructDecl, etc.).
    Declaration instantiate(TemplateDecl tmpl, Type[] typeArgs) {
        string key = mangleInstantiation(tmpl.name, typeArgs);
        if (auto cached = key in cache)
            return *cached;

        auto inst = reparseAndSubstitute(tmpl, typeArgs, key);
        cache[key] = inst;
        return inst;
    }

    /// Get all cached instantiations (for emitter collection).
    Declaration[] allInstantiations() {
        return cache.values;
    }

    /// Re-parse the template source text and substitute concrete types.
    private Declaration reparseAndSubstitute(TemplateDecl tmpl, Type[] typeArgs, string mangledName) {
        import parser.tree_sitter_bridge : TreeSitterBridge;

        // Extract source text from the template
        string src = tmpl.getSourceText();
        if (src is null)
            throw new Exception(format("Template '%s' has no stored source text", tmpl.name));

        // Re-parse to get fresh, independent AST
        auto bridge = new TreeSitterBridge("<template:" ~ mangledName ~ ">", src);
        Declaration[] parsed = bridge.parseSourceFile();

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

        // Build name → concrete type map from template params
        Type[string] typeMap;
        foreach (i, tp; tmpl.templateParams)
            typeMap[tp.paramName] = typeArgs[i];

        // Substitute types in all members
        foreach (member; freshTmpl.members) {
            substituteInDeclaration(member, typeMap);
        }

        // Substitute types in constraint and evaluate via CTFE
        if (freshTmpl.constraint !is null) {
            substituteInExpression(freshTmpl.constraint, typeMap);
            if (constraintEvaluator !is null) {
                constraintEvaluator(freshTmpl.constraint, tmpl.location);
            }
        }

        // Find and rename the eponymous member
        auto eponymous = freshTmpl.eponymousMember();
        if (eponymous is null)
            throw new Exception(format("Template '%s' has no eponymous member", tmpl.name));

        eponymous.name = mangledName;
        return eponymous;
    }

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
}

// ===== Type substitution helpers =====

/// Substitute types in a declaration (dispatches by declaration kind).
private void substituteInDeclaration(Declaration decl, Type[string] typeMap) {
    if (auto fd = cast(FunctionDecl)decl) {
        fd.returnType = substituteType(fd.returnType, typeMap);
        foreach (ref p; fd.parameters)
            p.type = substituteType(p.type, typeMap);
        if (fd.body_)
            substituteInStatement(fd.body_, typeMap);
    } else if (auto sd = cast(StructDecl)decl) {
        foreach (member; sd.members) {
            substituteInDeclaration(member, typeMap);
        }
    } else if (auto vd = cast(VariableDecl)decl) {
        vd.type = substituteType(vd.type, typeMap);
    }
}

/// Replace TemplateParamType nodes with concrete types.
private Type substituteType(Type type, Type[string] typeMap) {
    if (type is null) return null;

    if (auto tpt = cast(TemplateParamType)type) {
        if (auto concrete = tpt.paramName in typeMap)
            return *concrete;
        return type;
    }
    if (auto at = cast(ArrayType)type) {
        auto newElem = substituteType(at.elementType, typeMap);
        if (newElem !is at.elementType)
            at.elementType = newElem;
        return type;
    }
    if (auto pt = cast(PointerType)type) {
        auto newPointee = substituteType(pt.pointeeType, typeMap);
        if (newPointee !is pt.pointeeType)
            pt.pointeeType = newPointee;
        return type;
    }
    return type;
}

/// Walk a statement tree and substitute types.
private void substituteInStatement(Statement stmt, Type[string] typeMap) {
    if (stmt is null) return;

    if (auto cs = cast(CompoundStatement)stmt) {
        foreach (s; cs.statements)
            substituteInStatement(s, typeMap);
    } else if (auto ifs = cast(IfStatement)stmt) {
        substituteInExpression(ifs.condition, typeMap);
        substituteInStatement(ifs.thenStatement, typeMap);
        substituteInStatement(ifs.elseStatement, typeMap);
    } else if (auto ws = cast(WhileStatement)stmt) {
        substituteInExpression(ws.condition, typeMap);
        substituteInStatement(ws.body_, typeMap);
    } else if (auto fs = cast(ForStatement)stmt) {
        substituteInStatement(fs.init, typeMap);
        substituteInExpression(fs.condition, typeMap);
        substituteInExpression(fs.update, typeMap);
        substituteInStatement(fs.body_, typeMap);
    } else if (auto rs = cast(ReturnStatement)stmt) {
        substituteInExpression(rs.value, typeMap);
    } else if (auto es = cast(ExpressionStatement)stmt) {
        substituteInExpression(es.expression, typeMap);
    } else if (auto vds = cast(VariableDeclarationStatement)stmt) {
        vds.type = substituteType(vds.type, typeMap);
        substituteInExpression(vds.initializer, typeMap);
    }
}

/// Walk an expression tree and substitute types.
private void substituteInExpression(Expression expr, Type[string] typeMap) {
    if (expr is null) return;

    if (auto bin = cast(BinaryExpression)expr) {
        substituteInExpression(bin.left, typeMap);
        substituteInExpression(bin.right, typeMap);
    } else if (auto un = cast(UnaryExpression)expr) {
        substituteInExpression(un.operand, typeMap);
    } else if (auto call = cast(CallExpression)expr) {
        substituteInExpression(call.function_, typeMap);
        foreach (arg; call.arguments)
            substituteInExpression(arg, typeMap);
    } else if (auto ti = cast(TemplateInstantiationExpression)expr) {
        foreach (ref targ; ti.templateArguments)
            targ = substituteType(targ, typeMap);
        foreach (arg; ti.callArguments)
            substituteInExpression(arg, typeMap);
    } else if (auto idx = cast(IndexExpression)expr) {
        substituteInExpression(idx.array, typeMap);
        substituteInExpression(idx.index, typeMap);
    } else if (auto sl = cast(SliceExpression)expr) {
        substituteInExpression(sl.array, typeMap);
        substituteInExpression(sl.start, typeMap);
        substituteInExpression(sl.end, typeMap);
    } else if (auto mem = cast(MemberExpression)expr) {
        substituteInExpression(mem.object, typeMap);
    } else if (auto assign = cast(AssignmentExpression)expr) {
        substituteInExpression(assign.left, typeMap);
        substituteInExpression(assign.right, typeMap);
    } else if (auto cast_ = cast(CastExpression)expr) {
        cast_.targetType = substituteType(cast_.targetType, typeMap);
        substituteInExpression(cast_.expression, typeMap);
    } else if (auto arrLit = cast(ArrayLiteralExpression)expr) {
        foreach (elem; arrLit.elements)
            substituteInExpression(elem, typeMap);
    } else if (auto traits = cast(TraitsExpression)expr) {
        foreach (ref t; traits.typeArguments)
            t = substituteType(t, typeMap);
    }
}
