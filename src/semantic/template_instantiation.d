/**
 * Template Instantiation Driver
 *
 * Handles instantiation of function templates by re-parsing the template's
 * source text for each unique type argument combination. This produces
 * completely fresh, independent AST nodes for each instantiation — no
 * shared mutable state between different instantiations.
 */
module semantic.template_instantiation;

import ast.nodes;
import ast.statements;
import ast.expressions;
import std.array : join;
import std.format : format;

class TemplateInstantiator {
    private FunctionDecl[string] cache;

    /// Instantiate a template function for given type arguments.
    /// Returns the (possibly cached) instantiated FunctionDecl.
    FunctionDecl instantiate(FunctionDecl templateFunc, Type[] typeArgs) {
        string key = mangleInstantiation(templateFunc.name, typeArgs);
        if (auto cached = key in cache)
            return *cached;

        auto inst = reparseAndSubstitute(templateFunc, typeArgs, key);
        cache[key] = inst;
        return inst;
    }

    /// Get all cached instantiations (for emitter collection).
    FunctionDecl[] allInstantiations() {
        return cache.values;
    }

    /// Re-parse the template source text and substitute concrete types.
    private FunctionDecl reparseAndSubstitute(FunctionDecl templateFunc, Type[] typeArgs, string mangledName) {
        import parser.tree_sitter_bridge : TreeSitterBridge;

        // Extract source text from the template function
        string src = templateFunc.getSourceText();
        if (src is null)
            throw new Exception(format("Template function '%s' has no stored source text", templateFunc.name));

        // Re-parse to get fresh, independent AST
        auto bridge = new TreeSitterBridge("<template:" ~ mangledName ~ ">", src);
        Declaration[] parsed = bridge.parseSourceFile();

        // Find the function declaration in the parsed result
        FunctionDecl freshFunc = null;
        foreach (decl; parsed) {
            if (auto fd = cast(FunctionDecl)decl) {
                if (fd.name == templateFunc.name) {
                    freshFunc = fd;
                    break;
                }
            }
        }
        if (freshFunc is null)
            throw new Exception(format("Re-parse of template '%s' failed to produce a FunctionDecl", templateFunc.name));

        // Build name → concrete type map from template params
        Type[string] typeMap;
        foreach (i, tp; templateFunc.templateParams)
            typeMap[tp.paramName] = typeArgs[i];

        // Substitute TemplateParamType nodes with concrete types in the fresh AST
        freshFunc.returnType = substituteType(freshFunc.returnType, typeMap);
        foreach (ref p; freshFunc.parameters)
            p.type = substituteType(p.type, typeMap);
        if (freshFunc.body_)
            substituteInStatement(freshFunc.body_, typeMap);

        // Set mangled name and clear template status
        freshFunc.name = mangledName;
        freshFunc.templateParams = null;

        return freshFunc;
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
    }
}
