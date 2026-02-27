/**
 * Signature and source hashing for incremental compilation.
 *
 * Provides stable, non-cryptographic hashes for declaration signatures
 * and source text. Used by the dependency graph to detect what changed
 * (body-only vs signature change) and determine invalidation scope.
 *
 * Uses FNV-1a (64-bit) for speed and good distribution.
 */
module incremental.hasher;

import ast.nodes;

/// FNV-1a 64-bit hash constants
private enum ulong FNV_OFFSET = 14695981039346656037UL;
private enum ulong FNV_PRIME = 1099511628211UL;

/// Feed a byte into an FNV-1a accumulator.
private ulong fnvByte(ulong hash, ubyte b) {
    hash ^= b;
    hash *= FNV_PRIME;
    return hash;
}

/// Feed a string into an FNV-1a accumulator.
private ulong fnvString(ulong hash, string s) {
    foreach (ubyte b; cast(const(ubyte)[])s)
        hash = fnvByte(hash, b);
    // Separator so "ab","c" differs from "a","bc"
    hash = fnvByte(hash, 0xFF);
    return hash;
}

/// Hash a Type into the accumulator.
private ulong hashType(ulong hash, Type type) {
    if (type is null) {
        hash = fnvString(hash, "<null>");
        return hash;
    }

    if (auto bt = cast(BasicType)type) {
        hash = fnvString(hash, "basic");
        hash = fnvString(hash, bt.toString());
    } else if (auto ut = cast(UserType)type) {
        hash = fnvString(hash, "user");
        hash = fnvString(hash, ut.name);
        // Include resolved declaration identity if available
        if (ut.declaration !is null && ut.declaration.name.length > 0)
            hash = fnvString(hash, ut.declaration.name);
    } else if (auto at = cast(ArrayType)type) {
        if (at.arraySize !is null) {
            hash = fnvString(hash, "staticarray");
            hash = hashType(hash, at.elementType);
            hash = fnvString(hash, at.arraySize.toString());
        } else {
            hash = fnvString(hash, "array");
            hash = hashType(hash, at.elementType);
        }
    } else if (auto pt = cast(PointerType)type) {
        hash = fnvString(hash, "pointer");
        hash = hashType(hash, pt.pointeeType);
    } else if (auto ft = cast(FunctionType)type) {
        hash = fnvString(hash, "function");
        hash = hashType(hash, ft.returnType);
        foreach (p; ft.parameterTypes)
            hash = hashType(hash, p);
    } else {
        // Fallback: use toString
        hash = fnvString(hash, "other");
        hash = fnvString(hash, type.toString());
    }
    return hash;
}

/**
 * Hash a function's signature: return type + parameter types + attributes.
 * Body changes do NOT affect this hash.
 */
ulong hashFunctionSignature(FunctionDecl func) {
    ulong hash = FNV_OFFSET;
    hash = fnvString(hash, "func");
    hash = fnvString(hash, func.name);

    // Return type
    hash = hashType(hash, func.returnType);

    // Parameters (types + names, since renaming a param changes the ABI in D)
    foreach (param; func.parameters) {
        hash = hashType(hash, param.type);
        hash = fnvString(hash, param.name);
    }

    // Key attributes that affect calling convention / ABI
    if (func.attrs.isStatic_)
        hash = fnvString(hash, "static");
    if (func.isMethod)
        hash = fnvString(hash, "method");
    if (func.attrs.isExtern)
        hash = fnvString(hash, "extern");
    if (func.isCTFE)
        hash = fnvString(hash, "ctfe");

    return hash;
}

/**
 * Hash a struct's layout: field names, types, and order.
 * A change here means all users of the struct need re-codegen.
 */
ulong hashStructSignature(AggregateDecl agg) {
    ulong hash = FNV_OFFSET;
    hash = fnvString(hash, "struct");
    hash = fnvString(hash, agg.name);

    // Fields in order (name + type)
    foreach (field; agg.fields) {
        hash = fnvString(hash, field.name);
        hash = hashType(hash, field.type);
    }

    // Alias this (affects implicit conversion)
    foreach (at; agg.aliasThis)
        hash = fnvString(hash, at);

    return hash;
}

/**
 * Hash a manifest constant's signature: type + value.
 */
ulong hashManifestSignature(ManifestConstantDecl manifest) {
    ulong hash = FNV_OFFSET;
    hash = fnvString(hash, "manifest");
    hash = fnvString(hash, manifest.name);
    hash = hashType(hash, manifest.inferredType);

    // Include the value if available
    import std.conv : to;
    if (manifest.ctfeComplete) {
        if (manifest.isStringType)
            hash = fnvString(hash, manifest.ctfeStringValue);
        else if (manifest.isFloatType)
            hash = fnvString(hash, to!string(manifest.ctfeFloatValue));
        else
            hash = fnvString(hash, to!string(manifest.ctfeValue));
    }

    return hash;
}

/**
 * Hash a template's signature: template parameters + constraint presence.
 */
ulong hashTemplateSignature(TemplateDecl tmpl) {
    ulong hash = FNV_OFFSET;
    hash = fnvString(hash, "template");
    hash = fnvString(hash, tmpl.name);

    foreach (tp; tmpl.templateParams) {
        hash = fnvString(hash, tp.paramName);
        if (tp.valueType !is null)
            hash = hashType(hash, tp.valueType);
    }

    if (tmpl.constraint !is null)
        hash = fnvString(hash, "has_constraint");

    return hash;
}

/**
 * Hash a global variable's signature: type + name.
 */
ulong hashGlobalSignature(VariableDecl var) {
    ulong hash = FNV_OFFSET;
    hash = fnvString(hash, "global");
    hash = fnvString(hash, var.name);
    hash = hashType(hash, var.type);
    return hash;
}

/**
 * Hash arbitrary source text by byte range.
 * Used for body-change detection.
 */
ulong hashSourceText(string source, uint startByte, uint endByte) {
    ulong hash = FNV_OFFSET;
    if (startByte < source.length && endByte <= source.length && startByte < endByte) {
        foreach (ubyte b; cast(const(ubyte)[])source[startByte .. endByte])
            hash = fnvByte(hash, b);
    }
    return hash;
}
