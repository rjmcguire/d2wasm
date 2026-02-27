/**
 * Module Compiler — per-module compilers with a central controller.
 *
 * CompilationController coordinates across modules (shared state, phase ordering,
 * circular-import detection). Each ModuleCompiler owns a single module's compilation
 * and requests cross-module information from the controller.
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

/**
 * Central coordinator for multi-module compilation.
 *
 * Owns shared state (CTFE evaluator, modules context, circular-import set)
 * and creates per-module compilers on demand.
 */
class CompilationController {
    private ModuleRegistry registry;
    private string backendName;
    private bool enableStackTrace;
    private ParseFn parseFn;
    private Module rootModule;  // compilation entry point — its ST is used for CTFE

    // Per-module compilers, keyed by FQN
    private ModuleCompiler[string] compilers;

    // Lazy-initialized shared state
    private CTFEEvaluator ctfeEvaluator_;
    private ModulesContext modulesCtx_;

    // Circular import protection (lives here, not per-module)
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
            log(2, "CompilationController: circular import detected for ", fqn, ", proceeding");
            return;
        }

        advancing[fqn] = true;
        scope(exit) advancing.remove(fqn);

        auto mc = getCompiler(mod);
        mc.advanceTo(target);
    }

    /// Get or create a per-module compiler
    ModuleCompiler getCompiler(Module mod) {
        string fqn = mod.fullyQualifiedName();
        if (auto existing = fqn in compilers)
            return *existing;
        auto mc = new ModuleCompiler(mod, this);
        compilers[fqn] = mc;
        return mc;
    }

    /// Cross-module request: ensure a dependency reaches a phase
    void ensureDepPhase(Module dep, ModulePhase target) {
        ensurePhase(dep, target);
    }

    /// Shared ModulesContext (lazy)
    ModulesContext getModulesContext() {
        if (modulesCtx_ is null)
            modulesCtx_ = new ModulesContext(registry);
        return modulesCtx_;
    }

    /// Shared CTFE evaluator (lazy init on first type-check)
    CTFEEvaluator getCTFEEvaluator() {
        return ctfeEvaluator_;
    }

    /**
     * Lazy CTFE initialization. Called once before the first type-check.
     * All reachable modules are at symbolsCollected at this point.
     */
    void ensureCTFEReady(Module mod) {
        if (ctfeEvaluator_ !is null)
            return;

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

    /// Accessors for shared state (used by main.d)
    string backend() const { return backendName; }
}

/**
 * Per-module compiler. Owns one module's compilation and asks the
 * controller for anything cross-module.
 */
class ModuleCompiler {
    private Module module_;
    private CompilationController controller;

    this(Module mod, CompilationController controller) {
        this.module_ = mod;
        this.controller = controller;
    }

    /// Advance this module to the target phase
    void advanceTo(ModulePhase target) {
        if (module_.phase < ModulePhase.symbolsCollected && target >= ModulePhase.symbolsCollected)
            advanceToSymbolsCollected();
        if (module_.phase < ModulePhase.typeChecked && target >= ModulePhase.typeChecked)
            advanceToTypeChecked();
    }

    /**
     * Advance to symbolsCollected.
     * Interleaves mixin expansion with symbol collection using the real ST.
     */
    private void advanceToSymbolsCollected() {
        log(2, "ModuleCompiler: collecting symbols for ", module_.fullyQualifiedName());

        // 1. Create symbol table + module scope + builtins
        module_.symbolTable = new SymbolTable();
        module_.symbolTable.targetPtrSize = 4;
        module_.symbolTable.addBuiltinSymbols();
        module_.symbolTable.setModulePath(module_.modulePath);
        module_.symbolTable.initModuleScope(module_.modulePath);

        // 2. For each import dep: cascade to symbolsCollected via controller, then wire scope
        foreach (impDecl; module_.importDecls) {
            auto dep = cast(Module)impDecl.resolvedModule;
            if (dep is null)
                continue;
            controller.ensureDepPhase(dep, ModulePhase.symbolsCollected);
            wireImport(impDecl, dep);
        }

        // 3. Interleaved symbol collection + mixin expansion.
        auto mixinExpander = new MixinExpander(module_.symbolTable, controller.backend);
        module_.ast = mixinExpander.expandMixins(module_.ast);

        module_.phase = ModulePhase.symbolsCollected;
        log(2, "ModuleCompiler: symbols collected for ", module_.fullyQualifiedName());
    }

    /**
     * Advance to typeChecked.
     */
    private void advanceToTypeChecked() {
        log(2, "ModuleCompiler: type-checking ", module_.fullyQualifiedName());

        // 1. Ensure all deps are type-checked
        foreach (impDecl; module_.importDecls) {
            auto dep = cast(Module)impDecl.resolvedModule;
            if (dep is null)
                continue;
            controller.ensureDepPhase(dep, ModulePhase.typeChecked);
        }

        // 2. Lazy CTFE init (once, before first type-check)
        controller.ensureCTFEReady(module_);

        // 3. Type-check
        auto tc = new TypeChecker(module_.symbolTable);
        tc.checkDeclarations(module_.ast);

        // 4. Collect template instantiations
        auto mctx = controller.getModulesContext();
        foreach (inst; tc.templateInstantiator.allInstantiations()) {
            module_.ast ~= inst;
            mctx.addDeclaration(inst);
        }

        module_.phase = ModulePhase.typeChecked;
        log(2, "ModuleCompiler: type-checked ", module_.fullyQualifiedName());
    }

    /**
     * Wire an import's scope into this module's scope.
     */
    private void wireImport(ImportDecl impDecl, Module dep) {
        if (module_.symbolTable is null || module_.symbolTable.moduleScope is null)
            return;
        if (dep.symbolTable is null || dep.symbolTable.moduleScope is null)
            return;

        if (impDecl.moduleAlias.length > 0) {
            module_.symbolTable.moduleScope.addModuleAlias(
                impDecl.moduleAlias, dep.symbolTable.moduleScope);
        } else if (impDecl.selectiveImports.length > 0) {
            foreach (ref sel; impDecl.selectiveImports) {
                module_.symbolTable.moduleScope.addSelectiveImport(
                    sel.localName, dep.symbolTable.moduleScope, sel.remoteName);
            }
        } else {
            module_.symbolTable.moduleScope.addImport(dep.symbolTable.moduleScope);
        }
    }
}
