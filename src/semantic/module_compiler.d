/**
 * Module Compiler — lazy on-demand module compilation.
 *
 * Replaces the eager 3-pass pipeline in main.d with on-demand phase
 * advancement where each module compiles only when needed, and
 * mixin/static-if resolution is interleaved with symbol collection
 * using the real symbol table (with cross-module scope access).
 */
module semantic.module_compiler;

import ast.nodes;
import semantic.module_ : Module, ModulePhase;
import semantic.module_registry : ModuleRegistry;
import semantic.modules_context : ModulesContext;
import semantic.symbol_table : SymbolTable;
import semantic.ctfe : CTFEEvaluator;
import semantic.type_checker : TypeChecker;
import semantic.mixin_expander : MixinExpander, MixinError;

import diagnostic.log : log;

/// Parser factory: takes (filename, sourceText), returns Declaration[].
alias ParseFn = Declaration[] delegate(string filename, string sourceText);

class ModuleCompiler {
    private ModuleRegistry registry;
    private string backendName;
    private bool enableStackTrace;
    private ParseFn parseFn;
    private Module rootModule;  // compilation entry point — its ST is used for CTFE

    // Lazy-initialized
    private CTFEEvaluator ctfeEvaluator_;
    private ModulesContext modulesCtx_;

    // Circular import protection
    private bool[string] advancing;

    this(ModuleRegistry registry, ParseFn parseFn, string backendName,
         bool enableStackTrace, Module rootModule) {
        this.registry = registry;
        this.parseFn = parseFn;
        this.backendName = backendName;
        this.enableStackTrace = enableStackTrace;
        this.rootModule = rootModule;
    }

    /**
     * Ensure a module has reached at least the given phase.
     * Idempotent — does nothing if already at or past target.
     * Cascades to dependencies automatically.
     */
    void ensurePhase(Module mod, ModulePhase target) {
        if (mod.phase >= target)
            return;

        string fqn = mod.fullyQualifiedName();

        // Circular import protection: if we're already advancing this module,
        // its scope exists (created at the start of symbolsCollected) — just return.
        if (fqn in advancing) {
            log(2, "ModuleCompiler: circular import detected for ", fqn, ", proceeding");
            return;
        }

        advancing[fqn] = true;
        scope(exit) advancing.remove(fqn);

        // Advance through phases in order
        if (mod.phase < ModulePhase.symbolsCollected && target >= ModulePhase.symbolsCollected)
            advanceToSymbolsCollected(mod);
        if (mod.phase < ModulePhase.typeChecked && target >= ModulePhase.typeChecked)
            advanceToTypeChecked(mod);
    }

    /// Accessors for the lazy-initialized objects
    ModulesContext getModulesContext() {
        if (modulesCtx_ is null)
            modulesCtx_ = new ModulesContext(registry);
        return modulesCtx_;
    }

    CTFEEvaluator getCTFEEvaluator() {
        return ctfeEvaluator_;
    }

    // ── Phase transitions ──────────────────────────────────────────────

    /**
     * Advance a module to symbolsCollected.
     * Interleaves mixin expansion with symbol collection using the real ST.
     */
    private void advanceToSymbolsCollected(Module mod) {
        log(2, "ModuleCompiler: collecting symbols for ", mod.fullyQualifiedName());

        // 1. Create symbol table + module scope + builtins
        mod.symbolTable = new SymbolTable();
        mod.symbolTable.targetPtrSize = 4;
        mod.symbolTable.addBuiltinSymbols();
        mod.symbolTable.setModulePath(mod.modulePath);
        mod.symbolTable.initModuleScope(mod.modulePath);

        // 2. For each import dep: cascade to symbolsCollected, then wire scope
        foreach (impDecl; mod.importDecls) {
            auto dep = cast(Module)impDecl.resolvedModule;
            if (dep is null)
                continue;
            ensurePhase(dep, ModulePhase.symbolsCollected);
            wireImport(mod, impDecl, dep);
        }

        // 3. Interleaved symbol collection + mixin expansion.
        //    expandMixins with external ST pre-collects plain declarations
        //    (order-independent in D), then expands mixins/static-ifs and
        //    collects their results incrementally. No separate collectSymbols needed.
        auto mixinExpander = new MixinExpander(mod.symbolTable, backendName);
        mod.ast = mixinExpander.expandMixins(mod.ast);

        mod.phase = ModulePhase.symbolsCollected;
        log(2, "ModuleCompiler: symbols collected for ", mod.fullyQualifiedName());
    }

    /**
     * Advance a module to typeChecked.
     */
    private void advanceToTypeChecked(Module mod) {
        log(2, "ModuleCompiler: type-checking ", mod.fullyQualifiedName());

        // 1. Ensure all deps are type-checked
        foreach (impDecl; mod.importDecls) {
            auto dep = cast(Module)impDecl.resolvedModule;
            if (dep is null)
                continue;
            ensurePhase(dep, ModulePhase.typeChecked);
        }

        // 2. Lazy CTFE init (once, before first type-check)
        ensureCTFEReady(mod);

        // 3. Type-check
        auto tc = new TypeChecker(mod.symbolTable);
        tc.checkDeclarations(mod.ast);

        // 4. Collect template instantiations
        auto mctx = getModulesContext();
        foreach (inst; tc.templateInstantiator.allInstantiations()) {
            mod.ast ~= inst;
            mctx.addDeclaration(inst);
        }

        mod.phase = ModulePhase.typeChecked;
        log(2, "ModuleCompiler: type-checked ", mod.fullyQualifiedName());
    }

    /**
     * Lazy CTFE initialization. Called once before the first type-check.
     * All reachable modules are at symbolsCollected at this point.
     */
    private void ensureCTFEReady(Module mod) {
        if (ctfeEvaluator_ !is null)
            return;

        // Ensure the input module has its ST ready (it's at symbolsCollected
        // by the time any module reaches type-checking)
        auto mctx = getModulesContext();

        ctfeEvaluator_ = new CTFEEvaluator(
            rootModule.symbolTable, mctx, backendName, enableStackTrace);

        // Register CTFE resolver on ALL module symbol tables
        foreach (m; registry.allModules()) {
            if (m.symbolTable !is null) {
                m.symbolTable.ctfeResolver = &ctfeEvaluator_.evaluateManifestConstant;
                m.symbolTable.constraintEvaluator = &ctfeEvaluator_.evaluateTemplateConstraint;
            }
        }
    }

    /**
     * Wire an import's scope into the importing module's scope.
     */
    private void wireImport(Module mod, ImportDecl impDecl, Module dep) {
        if (mod.symbolTable is null || mod.symbolTable.moduleScope is null)
            return;
        if (dep.symbolTable is null || dep.symbolTable.moduleScope is null)
            return;

        if (impDecl.moduleAlias.length > 0) {
            mod.symbolTable.moduleScope.addModuleAlias(
                impDecl.moduleAlias, dep.symbolTable.moduleScope);
        } else if (impDecl.selectiveImports.length > 0) {
            foreach (ref sel; impDecl.selectiveImports) {
                mod.symbolTable.moduleScope.addSelectiveImport(
                    sel.localName, dep.symbolTable.moduleScope, sel.remoteName);
            }
        } else {
            mod.symbolTable.moduleScope.addImport(dep.symbolTable.moduleScope);
        }
    }
}
