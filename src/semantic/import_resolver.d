/**
 * Import Resolver — drives the parse-on-demand loop for multi-module compilation.
 *
 * Given a root module, recursively resolves its imports:
 *   find file → parse → register → recurse.
 *
 * D allows circular imports — when module A is being resolved and B imports A,
 * the resolver finds A already registered and short-circuits.
 */
module semantic.import_resolver;

import std.array : join;
import std.string : format;
import std.file : readText, exists;
import std.path : baseName, stripExtension, absolutePath;

import ast.nodes;
import ast.statements;
import semantic.module_ : Module, ModulePhase;
import semantic.module_registry : ModuleRegistry;
import ast.nodes : SourceLocation;

/**
 * Import resolution error with source location.
 */
class ImportError : Exception {
    SourceLocation location;

    this(string message, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(format("%s at %s", message, location.toString()), file, line);
    }
}

/**
 * Resolves import declarations by locating, parsing, and registering modules.
 */
class ImportResolver {
    private ModuleRegistry registry;
    private bool[string] resolving;  // cycle detection set

    import parser.source_parser : ParseFn;
    private ParseFn parseFn;

    this(ModuleRegistry registry, ParseFn parseFn) {
        this.registry = registry;
        this.parseFn = parseFn;
    }

    /**
     * Recursively resolve all imports for a module.
     * Safe to call multiple times — already-resolved modules are skipped.
     */
    void resolveImports(Module mod) {
        import diagnostic.log : log;

        string fqn = mod.fullyQualifiedName();

        // Cycle detection: if we're already resolving this module, short-circuit
        if (fqn in resolving)
            return;

        // Already resolved?
        if (mod.importDecls.length == 0 && mod.phase >= ModulePhase.parsed) {
            // Scan AST for ImportDecls — both top-level and inside function bodies
            scanDeclsForImports(mod.ast, mod.importDecls);
        }

        resolving[fqn] = true;
        scope(exit) resolving.remove(fqn);

        foreach (importDecl; mod.importDecls) {
            string impFqn = importDecl.importPath.join(".");

            // Already registered?
            Module depMod = registry.lookupModule(impFqn);
            if (depMod !is null) {
                // Link and recurse (handles circular imports — resolving set prevents infinite loop)
                if (!hasModule(mod.imports, depMod))
                    mod.imports ~= depMod;
                importDecl.resolvedModule = depMod;
                resolveImports(depMod);
                continue;
            }

            // Locate the file
            string filePath = registry.resolveImportPath(importDecl.importPath, mod.sourceFilePath);
            if (filePath is null) {
                throw new ImportError(
                    format("Cannot find module '%s'", impFqn),
                    importDecl.location
                );
            }

            // Create module, read source, parse
            depMod = new Module();
            depMod.modulePath = importDecl.importPath.dup;
            depMod.sourceFilePath = absolutePath(filePath);
            depMod.phase = ModulePhase.located;

            log(2, "Resolving import: ", impFqn, " → ", filePath);

            // Read
            depMod.sourceText = readText(filePath);
            depMod.phase = ModulePhase.loaded;

            // Parse
            depMod.ast = parseFn(filePath, depMod.sourceText);
            depMod.phase = ModulePhase.parsed;

            // Check for module declaration — might override path
            foreach (decl; depMod.ast) {
                if (auto modDecl = cast(ModuleDecl)decl) {
                    depMod.modulePath = modDecl.modulePath.dup;
                    break;
                }
            }

            // Register
            registry.registerModule(depMod);

            // Link
            if (!hasModule(mod.imports, depMod))
                mod.imports ~= depMod;
            importDecl.resolvedModule = depMod;

            // Scan for ImportDecls in the new module — top-level and scoped
            scanDeclsForImports(depMod.ast, depMod.importDecls);

            // Recurse
            resolveImports(depMod);
        }
    }

}

/**
 * Scan a list of declarations for ImportDecls — top-level and inside function/method bodies.
 */
void scanDeclsForImports(Declaration[] decls, ref ImportDecl[] result) {
    foreach (decl; decls) {
        if (auto imp = cast(ImportDecl)decl)
            result ~= imp;
        else if (auto funcDecl = cast(FunctionDecl)decl)
            collectScopedImports(funcDecl.body_, result);
        else if (auto sd = cast(StructDecl)decl) {
            foreach (member; sd.members)
                if (auto method = cast(FunctionDecl)member)
                    collectScopedImports(method.body_, result);
        } else if (auto cd = cast(ClassDecl)decl) {
            foreach (member; cd.members)
                if (auto method = cast(FunctionDecl)member)
                    collectScopedImports(method.body_, result);
        }
    }
}

/**
 * Walk a statement tree to find ImportDeclarationStatements and collect their ImportDecls.
 * This discovers scoped imports inside function bodies for module resolution.
 */
private void collectScopedImports(Statement stmt, ref ImportDecl[] result) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            collectScopedImports(s, result);
    } else if (auto importStmt = cast(ImportDeclarationStatement)stmt) {
        foreach (imp; importStmt.importDecls)
            result ~= imp;
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        collectScopedImports(ifStmt.thenStatement, result);
        collectScopedImports(ifStmt.elseStatement, result);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        collectScopedImports(whileStmt.body_, result);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        collectScopedImports(forStmt.init, result);
        collectScopedImports(forStmt.body_, result);
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        collectScopedImports(tryStmt.tryBody, result);
        foreach (ref c; tryStmt.catches)
            collectScopedImports(c.body_, result);
        collectScopedImports(tryStmt.finallyBody, result);
    } else if (auto funcStmt = cast(FunctionDeclarationStatement)stmt) {
        collectScopedImports(funcStmt.funcDecl.body_, result);
    }
    // Other statement types (return, expression, var decl, break, continue, etc.)
    // cannot contain import statements.
}

private bool hasModule(Module[] arr, Module target) {
    foreach (m; arr)
        if (m is target) return true;
    return false;
}
