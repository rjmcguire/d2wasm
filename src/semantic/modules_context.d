/**
 * ModulesContext — indexed facade over module registry.
 *
 * Built once after import resolution, provides O(1) hash lookups
 * that replace all `foreach (decl; allDeclarations)` linear scans
 * in the emitter, CTFE evaluator, and dependency analyzer.
 *
 * Each module's AST is processed exactly once (no duplicates from
 * circular imports), and declarations are indexed by name for fast
 * cross-module resolution.
 */
module semantic.modules_context;

import ast.nodes;
import semantic.module_ : Module;
import semantic.module_registry : ModuleRegistry;

class ModulesContext {
    private Module[] topoModules;    // dependency order (all modules)

    // Indexed lookups (built in constructor)
    private FunctionDecl[][string] functionsByName;
    private ManifestConstantDecl[][string] manifestsByName;
    private TemplateDecl[][string] templatesByName;
    private StructDecl[][string] structsByName;
    private ClassDecl[][string] classesByName;

    this(ModuleRegistry registry) {
        this.topoModules = registry.topologicalOrder();

        // Build indexes from all modules
        foreach (mod; topoModules) {
            indexModule(mod);
        }
    }

    /// Index a single module's AST declarations.
    private void indexModule(Module mod) {
        foreach (decl; mod.ast) {
            if (auto fd = cast(FunctionDecl)decl) {
                if (!fd.isTemplate)
                    functionsByName[fd.name] ~= fd;
            } else if (auto md = cast(ManifestConstantDecl)decl) {
                manifestsByName[md.name] ~= md;
            } else if (auto td = cast(TemplateDecl)decl) {
                templatesByName[td.name] ~= td;
            } else if (auto sd = cast(StructDecl)decl) {
                structsByName[sd.name] ~= sd;
                // Also index struct methods
                foreach (m; sd.members) {
                    if (auto mf = cast(FunctionDecl)m)
                        functionsByName[mf.name] ~= mf;
                }
            } else if (auto cd = cast(ClassDecl)decl) {
                classesByName[cd.name] ~= cd;
                // Also index class methods
                foreach (m; cd.members) {
                    if (auto mf = cast(FunctionDecl)m)
                        functionsByName[mf.name] ~= mf;
                }
            }
        }
    }

    // ── Cross-module lookups ──────────────────────────────────────────

    /// Find function by name, preferring definitions with body over forward decls.
    FunctionDecl findFunction(string name) {
        if (auto p = name in functionsByName) {
            FunctionDecl forwardDecl;
            foreach (fd; *p) {
                if (fd.body_ !is null)
                    return fd;
                if (forwardDecl is null)
                    forwardDecl = fd;
            }
            return forwardDecl;
        }
        return null;
    }

    /// Find all functions with a given name (for overload resolution).
    FunctionDecl[] findFunctions(string name) {
        if (auto p = name in functionsByName)
            return *p;
        return null;
    }

    /// Find manifest constant by name.
    ManifestConstantDecl findManifest(string name) {
        if (auto p = name in manifestsByName) {
            foreach (md; *p)
                return md;
        }
        return null;
    }

    /// Find template by name.
    TemplateDecl findTemplate(string name) {
        if (auto p = name in templatesByName) {
            foreach (td; *p)
                return td;
        }
        return null;
    }

    /// Find struct by name.
    StructDecl findStruct(string name) {
        if (auto p = name in structsByName) {
            foreach (sd; *p)
                return sd;
        }
        return null;
    }

    /// Find class by name.
    ClassDecl findClass(string name) {
        if (auto p = name in classesByName) {
            foreach (cd; *p)
                return cd;
        }
        return null;
    }

    // ── Iteration ────────────────────────────────────────────────────

    /// All modules in topological (dependency) order.
    Module[] modulesInOrder() {
        return topoModules;
    }

    /// All manifest constants across all modules.
    ManifestConstantDecl[] allManifests() {
        ManifestConstantDecl[] result;
        foreach (bucket; manifestsByName.values) {
            result ~= bucket;
        }
        return result;
    }

    // ── Mutation (for template instantiations added after type checking) ──

    /// Add a declaration to the index (e.g., template instantiation).
    void addDeclaration(Declaration decl) {
        if (auto fd = cast(FunctionDecl)decl) {
            if (!fd.isTemplate)
                functionsByName[fd.name] ~= fd;
        } else if (auto md = cast(ManifestConstantDecl)decl) {
            manifestsByName[md.name] ~= md;
        } else if (auto td = cast(TemplateDecl)decl) {
            templatesByName[td.name] ~= td;
        } else if (auto sd = cast(StructDecl)decl) {
            structsByName[sd.name] ~= sd;
            foreach (m; sd.members) {
                if (auto mf = cast(FunctionDecl)m)
                    functionsByName[mf.name] ~= mf;
            }
        } else if (auto cd = cast(ClassDecl)decl) {
            classesByName[cd.name] ~= cd;
            foreach (m; cd.members) {
                if (auto mf = cast(FunctionDecl)m)
                    functionsByName[mf.name] ~= mf;
            }
        }
    }
}
