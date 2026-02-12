/**
 * Template Instantiation Driver
 *
 * Handles instantiation of function templates. Given a template FunctionDecl
 * and concrete type arguments, binds TemplateParamType nodes and creates
 * a thin wrapper FunctionDecl with a mangled name for codegen.
 */
module semantic.template_instantiation;

import ast.nodes;
import ast.expressions;
import std.array : join, array;
import std.algorithm : map;

class TemplateInstantiator {
    private FunctionDecl[string] cache;

    /// Instantiate a template function for given type arguments.
    /// Returns the (possibly cached) instantiated FunctionDecl.
    FunctionDecl instantiate(FunctionDecl templateFunc, Type[] typeArgs) {
        string key = mangleInstantiation(templateFunc.name, typeArgs);
        if (auto cached = key in cache)
            return *cached;

        // Bind: set each templateParams[i].boundType = typeArgs[i]
        foreach (i, tp; templateFunc.templateParams)
            tp.boundType = typeArgs[i];

        // Create a thin wrapper FunctionDecl that shares the same AST
        auto inst = createInstantiationDecl(templateFunc, key);
        cache[key] = inst;
        return inst;
    }

    /// Get all cached instantiations (for emitter collection)
    FunctionDecl[] allInstantiations() {
        return cache.values;
    }

    private FunctionDecl createInstantiationDecl(FunctionDecl templateFunc, string mangledName) {
        // Resolve parameter types: unwrap TemplateParamType to concrete types
        // so downstream code (emitter, type checker) sees BasicType etc. directly.
        Parameter[] resolvedParams;
        foreach (p; templateFunc.parameters) {
            Parameter rp;
            rp.type = p.type.resolve();
            rp.name = p.name;
            rp.defaultValue = p.defaultValue;
            resolvedParams ~= rp;
        }

        auto inst = new FunctionDecl(
            templateFunc.location,
            mangledName,
            templateFunc.returnType.resolve(),
            resolvedParams,
            templateFunc.body_,
        );
        // Not a template itself — shares the same body.
        // Parameter and return types are resolved to concrete types.
        return inst;
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
