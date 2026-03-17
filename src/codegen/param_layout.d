/**
 * Unified Parameter Layout — computes the canonical parameter ordering
 * for a function once, consumed by the emitter and both backends.
 *
 * The canonical ordering is: [this?, result_ptr?, arena?, user_params...]
 *
 * This eliminates the 5+ places that independently reconstruct hidden
 * parameter ordering and makes future named-parameter support easy.
 */
module codegen.param_layout;

import ast.nodes : Type, FunctionDecl, Parameter, ArrayType, UserType,
                   BasicType, InterfaceDecl;
import codegen.wasm.types : ValType;

/// Role of a parameter in the calling convention.
enum ParamRole : ubyte {
    this_,       /// hidden 'this' pointer (methods only)
    resultPtr,   /// hidden __result pointer (large return types)
    arena,       /// hidden __arena pointer (arena-allocating functions)
    user,        /// user-declared parameter from source code
}

/// A single parameter in the canonical layout.
struct ParamEntry {
    ParamRole role;
    string name;            /// "this", "__result", "__arena", or user param name
    Type type;              /// AST type (null for hidden params)
    ValType wasmType;       /// WASM ValType (i32 for all hidden params and pointers)
    uint byteSize;          /// 4 for WASM32 pointers, 8 for ARM64; varies for user params
    uint userIndex;         /// index into FunctionDecl.parameters (uint.max for hidden)
    uint uniqueLocalId;     /// from type checker (uint.max for hidden)
    bool isInterfaceParam;  /// expands to 2 WASM locals (obj_ptr + itable_ptr)

    bool isHidden() const { return role != ParamRole.user; }
}

/// Complete parameter layout for a function, computed once and consumed by all backends.
struct ParamLayout {
    ParamEntry[] entries;

    /// Precomputed indices for fast access (uint.max = absent)
    uint thisIndex = uint.max;
    uint resultPtrIndex = uint.max;
    uint arenaIndex = uint.max;
    uint firstUserIndex = uint.max;

    /// Counts
    uint hiddenCount;
    uint userCount;
    uint wasmLocalCount;    /// total WASM locals consumed (interface params count as 2)

    /// Precomputed WASM signature arrays
    ValType[] wasmParams;
    ValType[] wasmResults;

    /// Queries
    bool hasThis() const { return thisIndex != uint.max; }
    bool hasResultPtr() const { return resultPtrIndex != uint.max; }
    bool hasArena() const { return arenaIndex != uint.max; }

    /// Number of hidden params before user params — used by native backend
    /// for register offset calculation.
    uint regOffset() const { return hiddenCount; }

    /// Iterate only user params.
    const(ParamEntry)[] userParams() const {
        if (firstUserIndex == uint.max || userCount == 0) return null;
        return entries[firstUserIndex .. firstUserIndex + userCount];
    }

    /// Get the WASM local index for a given entry index
    /// (accounts for interface param expansion to 2 locals).
    uint wasmLocalIdx(uint entryIndex) const {
        uint idx = 0;
        foreach (i; 0 .. entryIndex) {
            idx += entries[i].isInterfaceParam ? 2 : 1;
        }
        return idx;
    }
}

/// Context flags that determine which hidden params are present.
struct ParamLayoutContext {
    bool isMethod;          /// has hidden 'this' pointer
    bool hasLargeReturn;    /// return type passed via hidden __result pointer
    bool needsArena;        /// function needs hidden __arena parameter
    bool isExportedMain;    /// "main" free function — suppresses arena param

    /// Map a D type to its WASM ValType. Passed by the emitter to avoid
    /// param_layout.d depending on emitter.d.
    ValType delegate(Type) typeMapper;

    /// Check if a return type is void.
    bool isVoidReturn;

    /// Return WASM ValType (only used when !isVoidReturn && !hasLargeReturn).
    ValType returnWasmType;

    /// Pointer size in bytes (4 for WASM32, 8 for ARM64).
    uint ptrSize = 4;
}

/// Compute the canonical parameter layout for a function.
ParamLayout computeParamLayout(FunctionDecl decl, ParamLayoutContext ctx) {
    ParamLayout layout;

    // --- Phase 1: Hidden params in canonical order ---

    if (ctx.isMethod) {
        layout.thisIndex = cast(uint)layout.entries.length;
        layout.entries ~= ParamEntry(
            ParamRole.this_, "this", null, ValType.i32,
            ctx.ptrSize, uint.max, uint.max, false
        );
    }

    if (ctx.hasLargeReturn) {
        layout.resultPtrIndex = cast(uint)layout.entries.length;
        layout.entries ~= ParamEntry(
            ParamRole.resultPtr, "__result", null, ValType.i32,
            ctx.ptrSize, uint.max, uint.max, false
        );
    }

    bool addArena = ctx.needsArena && !ctx.isExportedMain;
    if (addArena) {
        layout.arenaIndex = cast(uint)layout.entries.length;
        layout.entries ~= ParamEntry(
            ParamRole.arena, "__arena", null, ValType.i32,
            ctx.ptrSize, uint.max, uint.max, false
        );
    }

    layout.hiddenCount = cast(uint)layout.entries.length;
    layout.firstUserIndex = layout.hiddenCount;

    // --- Phase 2: User params ---

    foreach (i, p; decl.parameters) {
        bool isIface = false;
        if (p.type) {
            isIface = p.type.asInterface() !is null;
        }

        // ref params are always pointer-sized (pass by reference)
        auto vt = p.isRef ? ValType.i32
                          : (ctx.typeMapper ? ctx.typeMapper(p.type) : ValType.i32);
        uint bsize = ctx.ptrSize;  // default for pointers
        if (!p.isRef && p.type) {
            auto sz = p.type.size();
            if (sz > 0) bsize = cast(uint)sz;
        }

        layout.entries ~= ParamEntry(
            ParamRole.user, p.name, p.type, vt,
            bsize, cast(uint)i,
            p.uniqueLocalId, isIface
        );
    }

    layout.userCount = cast(uint)decl.parameters.length;

    // --- Phase 3: Compute WASM local count and signature arrays ---

    uint wasmLocals = 0;
    ValType[] wparams;
    foreach (ref e; layout.entries) {
        wparams ~= e.wasmType;
        wasmLocals++;
        if (e.isInterfaceParam) {
            wparams ~= ValType.i32;  // second local for itable pointer
            wasmLocals++;
        }
    }
    layout.wasmLocalCount = wasmLocals;
    layout.wasmParams = wparams;

    // Return type
    if (!ctx.isVoidReturn && !ctx.hasLargeReturn) {
        layout.wasmResults = [ctx.returnWasmType];
    }

    return layout;
}
