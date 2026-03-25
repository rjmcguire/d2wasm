/**
 * Shared Function Collector
 *
 * Extracts compilable functions from declarations or modules.
 * Used by both WASM and native emitters to avoid duplicating
 * the function filtering logic.
 */
module codegen.function_collector;

import ast.nodes;
import semantic.modules_context : ModulesContext;
import semantic.module_ : Module;

/// Result of function collection
struct CollectedFunctions {
    FunctionDecl[] functions;
    ImportedFunctionDecl[] imports;
    FunctionDecl mainFunc;  // null if no main()
}

/// Per-module collected functions (preserves module context)
struct ModuleFunctions {
    Module mod;
    FunctionDecl[] functions;
    ImportedFunctionDecl[] imports;
}

/**
 * Collect compilable functions from a flat declaration list.
 * Filters out forward declarations, uninstantiated templates,
 * and non-function declarations.
 */
CollectedFunctions collectFunctions(Declaration[] decls) {
    CollectedFunctions result;

    foreach (decl; decls) {
        if (auto imp = cast(ImportedFunctionDecl)decl) {
            if (imp.moduleName == "ffi")
                result.imports ~= imp;
            continue;
        }
        // Collect methods from struct/class declarations
        if (auto aggDecl = cast(AggregateDecl)decl) {
            if (auto classDecl = cast(ClassDecl)decl) {
                if (classDecl.isObjC) {
                    // ObjC classes: only collect methods with D bodies
                    foreach (member; classDecl.members) {
                        auto method = cast(FunctionDecl)member;
                        if (method is null) continue;
                        if (method.body_ is null) continue;
                        result.functions ~= method;
                    }
                    continue;
                }
            }
            foreach (member; aggDecl.members) {
                auto method = cast(FunctionDecl)member;
                if (method is null) continue;
                if (method.body_ is null) continue;
                if (method.isTemplate) continue;
                result.functions ~= method;
            }
            continue;
        }
        auto funcDecl = cast(FunctionDecl)decl;
        if (funcDecl is null) continue;
        if (funcDecl.body_ is null) continue;     // forward declaration
        if (funcDecl.isTemplate) continue;          // uninstantiated template

        result.functions ~= funcDecl;
        if (funcDecl.name == "main")
            result.mainFunc = funcDecl;
    }

    return result;
}

/**
 * Collect compilable functions per-module, preserving module context.
 * Each module's functions are returned separately so the caller can
 * process them with the correct module source text and path.
 */
ModuleFunctions[] collectFunctionsPerModule(ModulesContext ctx) {
    ModuleFunctions[] result;

    foreach (mod; ctx.modulesInOrder()) {
        auto collected = collectFunctions(mod.ast);
        result ~= ModuleFunctions(mod, collected.functions, collected.imports);
    }

    return result;
}
