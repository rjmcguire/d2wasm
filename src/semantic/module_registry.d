/**
 * Module Registry — central store for all known compilation modules.
 *
 * Keyed by fully-qualified name (e.g., "animals.dog").
 * Provides import path resolution and dependency-ordered traversal.
 */
module semantic.module_registry;

import std.array : join;
import std.path : buildPath, dirName;
import std.file : exists;
import std.algorithm : map, filter, canFind;

import semantic.module_ : Module;

class ModuleRegistry {
    private Module[string] modules;

    /// Search paths for import resolution (from -I flags).
    string[] searchPaths;

    /**
     * Register a module. Overwrites if already present (allows re-registration
     * when a module advances to a later phase).
     */
    void registerModule(Module mod) {
        modules[mod.fullyQualifiedName()] = mod;
    }

    /**
     * Look up a module by fully-qualified name.
     * Returns null if not registered.
     */
    Module lookupModule(string fqn) {
        if (auto p = fqn in modules)
            return *p;
        return null;
    }

    /**
     * Look up a module by path components.
     */
    Module lookupModule(string[] path) {
        return lookupModule(path.join("."));
    }

    /**
     * All registered modules.
     */
    Module[] allModules() {
        return modules.values;
    }

    /**
     * Resolve an import path to a source file on disk.
     *
     * Resolution order:
     *   1. Relative to the importing file's directory
     *   2. Each -I search path, in order
     *
     * importPath: e.g., ["animals", "dog"]
     * importingFilePath: absolute path of the file containing the import statement
     *
     * Returns the resolved file path, or null if not found.
     */
    string resolveImportPath(string[] importPath, string importingFilePath) {
        // Try .d first, then .c (importC), then .js (importJS)
        static immutable extensions = [".d", ".c", ".js"];

        foreach (ext; extensions) {
            string relPath = buildModuleFilePath(importPath, ext);

            // 1. Relative to importing file's directory
            if (importingFilePath.length > 0) {
                string candidate = buildPath(dirName(importingFilePath), relPath);
                if (exists(candidate))
                    return candidate;
            }

            // 2. Search paths
            foreach (sp; searchPaths) {
                string candidate = buildPath(sp, relPath);
                if (exists(candidate))
                    return candidate;
            }
        }

        return null;
    }

    /**
     * Return modules in topological order (dependencies before dependents).
     * Uses Kahn's algorithm. Cycles are allowed in D — modules involved
     * in cycles are appended at the end.
     */
    Module[] topologicalOrder() {
        // Build in-degree map
        int[string] inDegree;
        string[][string] dependents; // fqn -> list of fqns that depend on it

        foreach (mod; modules.values) {
            string fqn = mod.fullyQualifiedName();
            if (fqn !in inDegree)
                inDegree[fqn] = 0;
            foreach (dep; mod.imports) {
                string depFqn = dep.fullyQualifiedName();
                if (depFqn !in inDegree)
                    inDegree[depFqn] = 0;
                inDegree[fqn]++;
                dependents[depFqn] ~= fqn;
            }
        }

        // Seed queue with zero-degree modules
        string[] queue;
        foreach (fqn, deg; inDegree) {
            if (deg == 0)
                queue ~= fqn;
        }

        Module[] result;
        while (queue.length > 0) {
            string fqn = queue[0];
            queue = queue[1 .. $];
            if (auto mod = lookupModule(fqn))
                result ~= mod;
            if (auto deps = fqn in dependents) {
                foreach (dep; *deps) {
                    inDegree[dep]--;
                    if (inDegree[dep] == 0)
                        queue ~= dep;
                }
            }
        }

        // Append any remaining modules (part of cycles)
        foreach (mod; modules.values) {
            if (!result.canFind(mod))
                result ~= mod;
        }

        return result;
    }

    /**
     * Convert a module path to a relative file path.
     * ["animals", "dog"] → "animals/dog.d" (or ".c" with extension override)
     */
    private static string buildModuleFilePath(string[] path, string ext = ".d") {
        import std.path : buildPath;
        if (path.length == 0)
            return "";
        if (path.length == 1)
            return path[0] ~ ext;
        // Join all components with path separator, append extension to the last
        string dir = "";
        foreach (i, component; path[0 .. $ - 1]) {
            dir = dir.length == 0 ? component : buildPath(dir, component);
        }
        return buildPath(dir, path[$ - 1] ~ ext);
    }
}
